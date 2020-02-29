## Install

```
# install pytorch 1.1 and torchvision
sudo pip3 install torch==1.1 torchvision

# install apex
cd $INSTALL_DIR
git clone https://github.com/NVIDIA/apex.git
cd apex
sudo python setup.py install --cuda_ext --cpp_ext

# clone Hier-R-CNN
git clone https://github.com/soeaver/Hier-R-CNN.git

# mask ops
cd Hier-R-CNN
sh make.sh

# make cocoapi
cd Hier-R-CNN/cocoapi/PythonAPI
mask
cd ../../
ln -s cocoapi/PythonAPI/pycocotools/ ./
```

