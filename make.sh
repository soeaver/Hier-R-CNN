#!/usr/bin/env bash

echo "Building Pet ops ..."
rm -rf build
rm -f models/ops/_C.*
python setup.py build_ext --inplace
rm -rf build
