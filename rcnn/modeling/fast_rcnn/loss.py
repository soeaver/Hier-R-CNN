import torch
from torch.nn import functional as F

from models.ops import smooth_l1_loss
from utils.data.structures.boxlist_ops import boxlist_iou
from rcnn.utils.box_coder import BoxCoder
from rcnn.utils.matcher import Matcher
from rcnn.utils.balanced_positive_negative_sampler import BalancedPositiveNegativeSampler
from rcnn.utils.misc import cat
from rcnn.core.config import cfg


class FastRCNNLossComputation(object):
    """
    Computes the loss for Faster R-CNN. Also supports FPN
    """

    def __init__(self, proposal_matcher, fg_bg_sampler, box_coder, cls_agnostic_bbox_reg=False, cls_on=True,
                 reg_on=True):
        """
        Arguments:
            proposal_matcher (Matcher)
            fg_bg_sampler (BalancedPositiveNegativeSampler)
            box_coder (BoxCoder)
            cls_agnostic_bbox_reg (Bool)
            cls_on (Bool)
            reg_on (Bool)
        """
        self.proposal_matcher = proposal_matcher
        self.fg_bg_sampler = fg_bg_sampler
        self.box_coder = box_coder
        self.cls_agnostic_bbox_reg = cls_agnostic_bbox_reg
        self.cls_on = cls_on
        self.reg_on = reg_on

    def match_targets_to_proposals(self, proposal, target):
        match_quality_matrix = boxlist_iou(target, proposal)
        matched_idxs = self.proposal_matcher(match_quality_matrix)
        # Fast RCNN only need "labels" field for selecting the targets
        target = target.copy_with_fields("labels")
        # get the targets corresponding GT for each proposal
        # NB: need to clamp the indices because we can have a single
        # GT in the image, and matched_idxs can be -2, which goes
        # out of bounds
        matched_targets = target[matched_idxs.clamp(min=0)]
        matched_targets.add_field("matched_idxs", matched_idxs)
        return matched_targets

    def prepare_targets(self, proposals, targets):
        labels = []
        regression_targets = []
        for proposals_per_image, targets_per_image in zip(proposals, targets):
            matched_targets = self.match_targets_to_proposals(
                proposals_per_image, targets_per_image
            )
            labels_per_image = None
            regression_targets_per_image = None

            if self.cls_on:
                matched_idxs = matched_targets.get_field("matched_idxs")

                labels_per_image = matched_targets.get_field("labels")
                labels_per_image = labels_per_image.to(dtype=torch.int64)

                # Label background (below the low threshold)
                bg_inds = matched_idxs == Matcher.BELOW_LOW_THRESHOLD
                labels_per_image[bg_inds] = 0

                # Label ignore proposals (between low and high thresholds)
                ignore_inds = matched_idxs == Matcher.BETWEEN_THRESHOLDS
                labels_per_image[ignore_inds] = -1  # -1 is ignored by sampler

            if self.reg_on:
                # compute regression targets
                regression_targets_per_image = self.box_coder.encode(
                    matched_targets.bbox, proposals_per_image.bbox
                )

            labels.append(labels_per_image)
            regression_targets.append(regression_targets_per_image)

        return labels, regression_targets

    def subsample(self, proposals, targets):
        """
        This method performs the positive/negative sampling, and return
        the sampled proposals.
        Note: this function keeps a state.

        Arguments:
            proposals (list[BoxList])
            targets (list[BoxList])
        """
        labels, regression_targets = self.prepare_targets(proposals, targets)
        sampled_pos_inds, sampled_neg_inds = self.fg_bg_sampler(labels)

        proposals = list(proposals)
        # add corresponding label and regression_targets information to the bounding boxes
        for labels_per_image, regression_targets_per_image, proposals_per_image in zip(
                labels, regression_targets, proposals
        ):
            if cfg.FAST_RCNN.CLS_ON:
                proposals_per_image.add_field("labels", labels_per_image)
            if cfg.FAST_RCNN.REG_ON:
                proposals_per_image.add_field(
                    "regression_targets", regression_targets_per_image
                )

        # distributed sampled proposals, that were obtained on all feature maps
        # concatenated via the fg_bg_sampler, into individual feature map levels
        for img_idx, (pos_inds_img, neg_inds_img) in enumerate(
                zip(sampled_pos_inds, sampled_neg_inds)
        ):
            img_sampled_inds = torch.nonzero(pos_inds_img | neg_inds_img).squeeze(1)
            proposals_per_image = proposals[img_idx][img_sampled_inds]
            proposals[img_idx] = proposals_per_image

        self._proposals = proposals
        return proposals

    def __call__(self, class_logits, box_regression):
        """
        Computes the loss for Faster R-CNN.
        This requires that the subsample method has been called beforehand.

        Arguments:
            class_logits (list[Tensor])
            box_regression (list[Tensor])

        Returns:
            classification_loss (Tensor)
            box_loss (Tensor)
        """
        loss_dict = {}

        if not hasattr(self, "_proposals"):
            raise RuntimeError("subsample needs to be called before")

        proposals = self._proposals
        labels = cat([proposal.get_field("labels") for proposal in proposals], dim=0)

        assert class_logits[0] is not None or box_regression[0] is not None, 'Fast R-CNN should keep 1 branch at least'

        if class_logits[0] is not None:
            class_logits = cat(class_logits, dim=0)
            classification_loss = F.cross_entropy(class_logits, labels)
            loss_dict["loss_classifier"] = classification_loss

        if box_regression[0] is not None:
            box_regression = cat(box_regression, dim=0)
            device = box_regression.device
            regression_targets = cat([proposal.get_field("regression_targets") for proposal in proposals], dim=0)

            # get indices that correspond to the regression targets for
            # the corresponding ground truth labels, to be used with
            # advanced indexing
            sampled_pos_inds_subset = torch.nonzero(labels > 0).squeeze(1)
            labels_pos = labels[sampled_pos_inds_subset]
            if self.cls_agnostic_bbox_reg:
                map_inds = torch.tensor([4, 5, 6, 7], device=device)
            else:
                map_inds = 4 * labels_pos[:, None] + torch.tensor([0, 1, 2, 3], device=device)

            box_loss = smooth_l1_loss(
                box_regression[sampled_pos_inds_subset[:, None], map_inds],
                regression_targets[sampled_pos_inds_subset],
                beta=cfg.FAST_RCNN.SMOOTH_L1_BETA,
                reduction="sum"
            )
            box_loss = box_loss / labels.numel()
            loss_dict["loss_box_reg"] = box_loss
        return loss_dict


def box_loss_evaluator():
    matcher = Matcher(
        cfg.FAST_RCNN.FG_IOU_THRESHOLD,
        cfg.FAST_RCNN.BG_IOU_THRESHOLD,
        allow_low_quality_matches=False,
    )

    bbox_reg_weights = cfg.FAST_RCNN.BBOX_REG_WEIGHTS
    box_coder = BoxCoder(weights=bbox_reg_weights)

    fg_bg_sampler = BalancedPositiveNegativeSampler(
        cfg.FAST_RCNN.BATCH_SIZE_PER_IMAGE, cfg.FAST_RCNN.POSITIVE_FRACTION
    )

    cls_agnostic_bbox_reg = cfg.FAST_RCNN.CLS_AGNOSTIC_BBOX_REG
    cls_on = cfg.FAST_RCNN.CLS_ON
    reg_on = cfg.FAST_RCNN.REG_ON

    loss_evaluator = FastRCNNLossComputation(
        matcher, fg_bg_sampler, box_coder, cls_agnostic_bbox_reg, cls_on, reg_on
    )

    return loss_evaluator
