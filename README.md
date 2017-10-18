# extract_marcxml_for_argot_unc
UNC's script to extract MARC-XML from Sierra ILS, for submission to Traject for translation into Argot

- Shared here because Duke may find it (or part of it) useful
- Uses MARC-XML to avoid record-length limits of MARC binary, which we would hit with some of the bibs that have many attached items, holdings, and/or order records (mainly items)

## Usage:
```
perl marc_for_argot.pl [path to input file] [path to output file]
```

## Options:
- --testing : prints extra info to STDOUT for checking out how things are being processed

## Input/output:
- bnums.txt - example input file - list of bib record numbers (no check digit). Comments after bnums ignored. Commented lines ignored.
- out.xml - example output file

## Other files:
- attached_record_data_mapping.csv - defines the custom 999 fields containing data from item, holdings, and (in some cases) order records attached to the bib record in the ILS.
- holdings_data_logic.org - instructions for transforming extracted MARC holdings data for use in public catalog

## Notes on preparing input file: 

SQL to select 100,000 random unsuppressed bibs from ILS:

``` sql
select 'b' || rm.record_num AS bnum
from sierra_view.bib_record b
inner join sierra_view.record_metadata rm
on b.id = rm.id
where b.is_suppressed = 'f'
order by random()
LIMIT 100000;
```
## Notes on processing output file: 
Split giant output file into 10,000 record files: 

``` awk
awk '/^ +<record>$/ { delim++ } { file = sprintf("UNC%s.xml", int(delim / 10000)); print >> file; }' < output.xml
```

If there's an extra 1-record file at the end:

``` bash
cat UNC9.xml UNC10.xml >> tail.xml
rm -f UNC9.xml
rm -f UNC10.xml
```

Rename the split file representing the head of the original file:

``` bash
mv UNC0.xml head.xml
```

Add the xml declaration and collection opening element to the beginning of all splitfile files and the tail file: 

``` sed
sed -i "1 i\<?xml version='1.0'?>\n<collection xmlns='http://www.loc.gov/MARC21/slim' xmlns:xsi='http://www.w3.org/2001/XMLSchema-instance' xsi:schemaLocation='http://www.loc.gov/MARC21/slim http://www.loc.gov/standards/marcxml/schema/MARC21slim.xsd'>" UNC*.xml

sed -i "1 i\<?xml version='1.0'?>\n<collection xmlns='http://www.loc.gov/MARC21/slim' xmlns:xsi='http://www.w3.org/2001/XMLSchema-instance' xsi:schemaLocation='http://www.loc.gov/MARC21/slim http://www.loc.gov/standards/marcxml/schema/MARC21slim.xsd'>" tail.xml
```

Add the collection closing element to the end of all splitfile files and the head file: 

``` bash
for file in UNC*.xml; do echo '</collection>' >> "$file"; done

echo '</collection>' >> head.xml
```

Rename head and tail files: 

``` bash
mv head.xml UNC0.xml ; mv tail.xml UNC9.xml
```

Validate resulting XML files: 

``` bash
xmllint --valid --noout UNC*.xml
```

If the only "errors" look like the following, you are good: 

```
UNC5.xml:2: validity error : Validation failed: no DTD found !
.loc.gov/MARC21/slim http://www.loc.gov/standards/marcxml/schema/MARC21slim.xsd'
```

Zip the files (one .gz per file): 

``` bash
gzip UNC*.xml
```

