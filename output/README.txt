XML output files are kept under vc in the testing directory because:
- they are small
- they are the ones I'm shuffling back and forth across machines most often

output/ingested is in .gitignore for now because there will be massive files in there. 
The big output XML files can be zipped up and stored in S3.