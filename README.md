# Hier-R-CNN
Hier R-CNN: Instance-level Human Parts Detection and A New Benchmark

In this repository, we release the COCO Human Parts dataset and Hier R-CNN code in Pytorch.


## Installation

Install Hier R-CNN following [INSTALL.md](https://github.com/soeaver/Hier-R-CNN/blob/master/INSTALL.md).


## ImageNet pretrained weight

- [VoVNet-39](https://dl.dropbox.com/s/s7f4vyfybyc9qpr/vovnet39_statedict_norm.pth?dl=1)
- [VoVNet-57](https://dl.dropbox.com/s/b826phjle6kbamu/vovnet57_statedict_norm.pth?dl=1)
- [VoVNet-75](https://dl.dropbox.com/s/ve1h1ol2ge7yfta/vovnet75_statedict_norm.pth.tar?dl=1)
- [VoVNet-93](https://dl.dropbox.com/s/qtly316zv1isn0t/vovnet93_statedict_norm.pth.tar?dl=1)


## Training

To train a model with 8 GPUs run:
```
python -m torch.distributed.launch --nproc_per_node=8 tools/train_net.py --cfg cfgs/mscoco_humanparts/e2e_hier_rcnn_R-50-FPN_1x.yaml
```


## Evaluation

Model evaluation can be done similarly:
```
python tools/test_net.py --cfg ckpts/mscoco_humanparts/e2e_hier_rcnn_R-50-FPN_1x/e2e_hier_rcnn_R-50-FPN_1x.yaml --gpu_id 0,1,2,3,4,5,6,7
```
