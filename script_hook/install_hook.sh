#!/bin/bash 
set -e 

ls -la 

cp pre-commit ../.git/hooks/pre-commit
chmod +x ../.git/hooks/pre-commit