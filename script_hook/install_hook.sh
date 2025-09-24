#!/bin/bash 
set -e 
WORKDIR=$(pwd)
 
cd ../.git/hooks/
ls -la
rm -f * 

cp "$WORKDIR/pre-commit" pre-commit
chmod +x pre-commit