#!/usr/bin/env bash

# oops, not the json
# sed 's/{"id":"\(UNC[^"]*\).*/\1/' *.json > _all_the_bnums.out

# okay
sed -ne '/<datafield ind1=. . ind2=. . tag=.907.>/,/code/p' *.xml | sed -n 's/.*\(b[0-9]*\)<.*/\1/p' | sort | uniq > _all_the_bnums.out

