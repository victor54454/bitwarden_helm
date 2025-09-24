#!/bin/bash 
set -e 

ls -la 
cd ../.git/hooks/
ls -la
rm * 

find / -type f -name values.*.yaml 

cp pre-commit ../.git/hooks/pre-commit
chmod +x ../.git/hooks/pre-commit