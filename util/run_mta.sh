#! /bin/bash

#cd /mnt/c/code/marc-to-argot
#git pull
#rake install

MARCPATH=$1
ARGOTPATH=$3

for f in $MARCPATH
do
    filename=$(basename -- "$fullfile")
    filename=${f%.*}
    echo "$filename"
    extension=${f##*.}
    echo "$extension"
done




