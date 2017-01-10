# extract_marcxml_for_argot_unc
UNC's script to extract MARC-XML from Sierra ILS, for submission to Traject for translation into Argot

- Shared here because Duke may find it (or part of it) useful
- Uses MARC-XML to avoid record-length limits of MARC binary, which we would hit with some of the bibs that have many attached items, holdings, and/or order records (mainly items)

Usage: 
```
perl marc_for_argot.pl [path to input file] [path to output file]
```

Options: 
- --testing : prints extra info to STDOUT for checking out how things are being processed

Input/output:
- bnums.txt - example input file - list of bib record numbers (no check digit). Comments after bnums ignored. Commented lines ignored.
- out.xml - example output file
