#!/bin/bash 
set -e 
WORKDIR=$(pwd)
 
cd ../.git/hooks/
ls -la
rm -f * 

cp "$WORKDIR/pre-commit" pre-commit
cp "$WORKDIR/post-commit" post-commit
chmod +x pre-commit
chmod +x post-commit
