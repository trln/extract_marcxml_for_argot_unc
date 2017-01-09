#!/usr/bin/perl
#
# Summary: Takes list of III ILS bnums (sans check digit) and returns MARC-XML record with
#          required item, holding, & order data for discovery service.
#
# Usage: perl marc_for_argot.pl [input file] [output file]
#
# Author: Kristina Spurgin (2015-07-29 - )
#
# Dependencies:
#    /scripts/endeca/bnums_test/afton_iii_sierra_perl.inc
#
# Important usage notes:
# UTF8 is the biggest factor in this script.  in addition to the use utf8
# declaration at the head of the script, we must also explicitly set the mode of
# any output to utf8.

#***********************************************************************************
# Declarations
#***********************************************************************************

use DBI;
use  DBD::Oracle;
use utf8;
use locale;
use Net::SSH2;
use List::Util qw(first);
use File::Basename;
use Getopt::Long; #allows for use of testing mode, http://perldoc.perl.org/Getopt/Long.html

# set character encoding for stdout to utf8
binmode(STDOUT, ":utf8");

#************************************************************************************
# Set up environment and make sure it is clean
#************************************************************************************
$ENV{'PATH'} = '/bin:/usr/sbin';
delete @ENV{'ENV', 'BASH_ENV'};
$ENV{'NLS_LANG'} = 'AMERICAN_AMERICA.AL32UTF8';

my $testing = '';

GetOptions ('testing' => \$testing);


my($dbh, $sth);

use DBD::Pg;
$input = '/scripts/endeca/bnums_test/afton_iii_sierra_perl.inc';

open (INFILE, "<$input") || die &mail_error("Can't open Sierra DB connects file\n");

while (<INFILE>) {
    chomp;
    @pair = split("=", $_);
    $mycnf{$pair[0]} = $pair[1];
}

close(INFILE);

my $host = $mycnf{"host"};
my $port = $mycnf{"port"};
my $dbname = $mycnf{"dbname"};
my $username = $mycnf{"user"};
my $password = $mycnf{"password"};

# untaint all of the db connection variables
if ($host =~ /^([-\@\w.]+)$/) {
    $host=$1;
} else {
    die "Bad data in $host";
}

if ($port =~ /^([-\@\w.]+)$/) {
    $port=$1;
} else {
    die "Bad data in $port";
}

if ($dbname =~ /^([-\@\w.]+)$/) {
    $dbname=$1;
} else {
    die "Bad data in $dbname";
}

if ($username =~ /^([-\@\w.]+)$/) {
    $username=$1;
} else {
    die "Bad data in $username";
}


$dbh = DBI->connect("dbi:Pg:host=$host;port=$port;dbname=$dbname", $username, $password)
    or die &mail_error("Unable to connect: $DBI::errstr");

# So we don't have to check every DBI call we set RaiseError.
$dbh->{pg_enable_utf8} = 1;
$dbh->{RaiseError} = 1;

#**************************************
# Get your files in order...
#**************************************
#set bnum list
$bnum_file = $ARGV[0];

# open file to write output
# the single most crucial part of this script is to specify the output format as utf8
my $out_path = $ARGV[1];
open(OUTFILE, ">:utf8", "$out_path") or die &mail_error("Couldn't open $out_path for output: $!\n");

my($out_path_file, $out_path_dir, $out_path_ext) = fileparse($out_path);

my $warn_path = "$out_path_dir/bib_errors.txt";
open (WARN, ">:utf8", "$warn_path") or die &mail_error("Couldn't open $warn_path for output: $!\n");

my $warning_ct = 0;

#******************************************
# Build MARC-XML for items in input file
#******************************************
print OUTFILE "<?xml version='1.0'?>\n";
print OUTFILE "<collection xmlns='http://www.loc.gov/MARC21/slim' xmlns:xsi='http://www.w3.org/2001/XMLSchema-instance' xsi:schemaLocation='http://www.loc.gov/MARC21/slim http://www.loc.gov/standards/marcxml/schema/MARC21slim.xsd'>\n";

open (INFILE, "<$bnum_file") || die &mail_error("Can't open bnum file: $bnum_file\n");

RECORD: while (<INFILE>) {
    chomp;
    my $bnum = $_ ;
    $bnum =~ s/(^b\d+).*/\1/;
    my $numbnum = $bnum;
    $numbnum =~ s/^b//;
    my @ids;

    #Get bib id for the bib number. This will also write a warning if the bnum is not found in the database.
    my $bib_id_sql = "
       SELECT id
       FROM sierra_view.record_metadata
       WHERE record_num = '$numbnum'
       AND record_type_code = 'b'";
    my $bib_id_sth = $dbh->prepare($bib_id_sql);
    $bib_id_sth->execute();
    my $bib_id;
    $bib_id_sth->bind_columns (undef, \$bib_id );
    while ($bib_id_sth->fetch()) {
        push @ids, $bib_id;
    }
    $bib_id_sth->finish();

    my $ct_ids = scalar @ids;
    if ($ct_ids == 1) {
        #open the MARC-XML record
        print OUTFILE "  <record>\n";
        if ($testing) {
            print "BibID: $bib_id\n";
        }
        } elsif ($ct_ids == 0) {
            print WARN "$bnum \tThere is no bib record with this bib record id. Perhaps the full record id from Millennium was entered (check digit should be omitted), or there was a copy/paste error?\n";
            $warning_ct += 1;
            next RECORD;
        } else {
            print WARN "$bnum \tThere is somehow more than one record with this bib record id.\n";
            $warning_ct += 1;
            next RECORD;
        }

    #Make sure record has 1 and only 1 LDR field. If so, write Leader.
    #TODO: Do this later. For now we assume each existing record has the Leader it should
    my $rec_length = '00000';
    my ($rec_status, $rec_type, $blvl, $ctrl_type, $char_enc);
    my $indicator_ct = '2';
    my $subf_ct = '2';
    my ($base_address, $elvl, $desc_form, $multipart);
    #$base_address should be 5 characters/digits, left-padded with zeros
    my $ldr_end = '4500';

    my $ldr_sql = "
          SELECT
            COALESCE(record_status_code, ' '),
            COALESCE(record_type_code, ' '),
            COALESCE(bib_level_code, ' '),
            COALESCE(control_type_code, ' '),
            COALESCE(char_encoding_scheme_code, ' '),
            COALESCE(encoding_level_code, ' '),
            COALESCE(descriptive_cat_form_code, ' '),
            COALESCE(multipart_level_code, ' '),
            COALESCE(LPAD(base_address::text, 5, '0'), '00000')
          FROM sierra_view.leader_field
          WHERE record_id = $bib_id
          ";
    my $ldr_sth = $dbh->prepare($ldr_sql);
    $ldr_sth->execute();
    #   $bib_sth->bind_columns (undef, \$marc_tag, \$rec_data, \$ind1, \$ind2 );
    $ldr_sth->bind_columns (undef, \$rec_status, \$rec_type, \$blvl, \$ctrl_type, \$char_enc, \$elvl, \$desc_form, \$multipart, \$base_address);
    while ($ldr_sth->fetch()) {
        my $ldr = $rec_length . $rec_status . $rec_type . $blvl . $ctrl_type . $char_enc . $indicator_ct . $subf_ct . $base_address . $elvl . $desc_form . $multipart . $ldr_end;
        print OUTFILE "    <leader>$ldr</leader>\n";
        $ldr_length = length ($ldr);
        if ($ldr_length != 24) {
            print WARN "$bnum_full\tThis Leader in this bib record does not include 24 characters. Report to cataloging staff to fix record.\n";
            $warning_ct += 1;
        }
    }
    $ldr_sth->finish();

    #Get and write control fields
    #MARC-XML defines control fields as MARC21 Fields 001-009
    #Helpfully, Sierra puts 006, 007, and 008 in the control_fields table, but leaves the other 00X
    #  fields in the variable fields table.
    #TODO: Maybe: sort these better
    #For now: any 006s, 007s, and 008s are output first, then the other 00X fields follow.
    my $cf_sql = "
           select LPAD(control_num::TEXT, 3, '0'),
           coalesce(nullif(p00, ''), '#') ||
           coalesce(nullif(p01, ''), '#') ||
           coalesce(nullif(p02, ''), '#') ||
           coalesce(nullif(p03, ''), '#') ||
           coalesce(nullif(p04, ''), '#') ||
           coalesce(nullif(p05, ''), '#') ||
           coalesce(nullif(p06, ''), '#') ||
           coalesce(nullif(p07, ''), '#') ||
           coalesce(nullif(p08, ''), '#') ||
           coalesce(nullif(p09, ''), '#') ||
           coalesce(nullif(p10, ''), '#') ||
           coalesce(nullif(p11, ''), '#') ||
           coalesce(nullif(p12, ''), '#') ||
           coalesce(nullif(p13, ''), '#') ||
           coalesce(nullif(p14, ''), '#') ||
           coalesce(nullif(p15, ''), '#') ||
           coalesce(nullif(p16, ''), '#') ||
           coalesce(nullif(p17, ''), '#') ||
           coalesce(nullif(p18, ''), '#') ||
           coalesce(nullif(p19, ''), '#') ||
           coalesce(nullif(p20, ''), '#') ||
           coalesce(nullif(p21, ''), '#') ||
           coalesce(nullif(p22, ''), '#') ||
           coalesce(nullif(p23, ''), '#') ||
           coalesce(nullif(p24, ''), '#') ||
           coalesce(nullif(p25, ''), '#') ||
           coalesce(nullif(p26, ''), '#') ||
           coalesce(nullif(p27, ''), '#') ||
           coalesce(nullif(p28, ''), '#') ||
           coalesce(nullif(p29, ''), '#') ||
           coalesce(nullif(p30, ''), '#') ||
           coalesce(nullif(p31, ''), '#') ||
           coalesce(nullif(p32, ''), '#') ||
           coalesce(nullif(p33, ''), '#') ||
           coalesce(nullif(p34, ''), '#') ||
           coalesce(nullif(p35, ''), '#') ||
           coalesce(nullif(p36, ''), '#') ||
           coalesce(nullif(p37, ''), '#') ||
           coalesce(nullif(p38, ''), '#') ||
           coalesce(nullif(p39, ''), '#')
           from sierra_view.control_field
           where record_id = $bib_id
           order by occ_num ASC
           ";

    my $cf_sth = $dbh->prepare($cf_sql);
    $cf_sth->execute();
    my ($marc_tag, $data);
    $cf_sth->bind_columns (undef, \$marc_tag, \$data);

  CTRLFIELD: while ($cf_sth->fetch()) {
        $data =~ s/#/ /g;
        if ($marc_tag =~ m/00[67]/) {
            $data =~ s/ *$//;
        }
        print OUTFILE "      <controlfield tag='$marc_tag'>$data</controlfield>\n";
    } #end CTRLFIELD

    #Now, handle the control fields stored as variable fields in Sierra
        my $vcf_sql = "
           select marc_tag, field_content
           from sierra_view.varfield
           where record_id = $bib_id
           and marc_tag IN ('001', '003', '005')
           order by marc_tag, occ_num ASC
           ";

    my $vcf_sth = $dbh->prepare($vcf_sql);
    $vcf_sth->execute();
    my ($marc_tag, $data);
    $vcf_sth->bind_columns (undef, \$marc_tag, \$data);

  VCTRLFIELD: while ($vcf_sth->fetch()) {
        print OUTFILE "      <controlfield tag='$marc_tag'>$data</controlfield>\n";
    } #end VCTRLFIELD

  #   #Set up to grab the rest of the fields and process them
  #   my $bib_sql = "select marc_tag, rec_data, indicator1, indicator2
  #                   from var_fields2
  #                   where rec_key = '$bnum' and iii_tag != '_' and marc_tag IS NOT NULL
  #                   order by marc_tag, rec_seq";

  #   my $bib_sth = $dbh->prepare($bib_sql);
  #   $bib_sth->execute();
  #   my ($marc_tag, $rec_data, $ind1, $ind2) = ('', '', '', '');
  #   $bib_sth->bind_columns (undef, \$marc_tag, \$rec_data, \$ind1, \$ind2 );

  #   #Set up counters and things for verification
  #   my $oclc035 = 0; #set to 1 if 035 contains OCoLC
  #   my $ct008 = 0;   #each 008 field increments count by 1
  #   my $ct245 = 0;   #each 245 field increments count by 1
  #   my $ct245ak = 0; #incremented by 1 if 245 contains subfield a or k
  #   my $orig001 = ""; #hold the value from the 001 field in case there's no 035 with OCLC num
  #   my $orig003 = ""; #hold the record source code to determine if $orig001 is an OCLC num or not

  #   #provide Hathi-specific 001 and 003
  #   #Hathi ingests from IA provided bnum without check digit in the 001
  #   print OUTFILE "      <controlfield tag='001'>$bnum</controlfield>\n";
  #   print OUTFILE "      <controlfield tag='003'>NcU</controlfield>\n";

  # FIELD: while ($bib_sth->fetch()) {
  #       #Escape XML-reserved characters in the data
  #       if ($rec_data =~ m/[<>&"']/) {
  #           $rec_data = escape_xml_reserved ($rec_data);
  #       }

  #       #Process control fields
  #       if ($marc_tag =~ m/00\d/) {
  #           if ($marc_tag =~ m/001/) {
  #               $orig001 = $rec_data;
  #           } elsif ($marc_tag =~ m/003/) {
  #               $orig003 = $rec_data;
  #           } else {
  #               if ($marc_tag == '008') {
  #                   $ct008 += 1;
  #                   #III for some ridiculous reason chooses to output the 6 editable LDR bytes on the end of the 008
  #                   #So those need to be deleted to create valid MARC
  #                   $rec_data =~ s/^(.*)......$/\1/;
  #                   my $length008 = length($rec_data);
  #                   if ($length008 != 40) {
  #                       print WARN "$bnum_full\tThis bib record's 008 does not have 40 byte positions. Report to cataloging staff to correct 008.\n";
  #                       $warning_ct += 1;
  #                   }
  #               }
  #               print OUTFILE "      <controlfield tag='$marc_tag'>$rec_data</controlfield>\n";
  #           }
  #       }

  #       #Hathi doesn't need our 9XX fields
  #       elsif ( $marc_tag =~ m/^9/ ) {
  #           next FIELD;
  #       }

  #       #Process variable fields
  #       else {
  #           print OUTFILE "      <datafield ind1='$ind1' ind2='$ind2' tag='$marc_tag'>\n";
  #           my @subfields = split /\|/, "$rec_data";
  #           # need to get ordered list of delimiters in fields so we can throw errors
  #           #  if some fields don't start with (or contain) required subfields
  #           my @delimiters = ();
  #           foreach my $subfield (@subfields) {
  #               if ($subfield) {
  #                   my $delimiter = substr ($subfield, 0, 1);
  #                   my $data = trim (substr ($subfield, 1));
  #                   print OUTFILE "        <subfield code='$delimiter'>$data</subfield>\n";
  #                   push @delimiters, $delimiter;
  #               }
  #           }
  #           print OUTFILE "      </datafield>\n";

  #           if ($marc_tag == '245') {
  #               $ct245 += 1;
  #               if (first { $_ eq ('a' || 'k') } @delimiters) {
  #                   $ct245ak += 1;
  #               }
  #           }
  #           if ($marc_tag == '035' && $rec_data =~ m/\|a\(OCoLC\)/) {
  #               $oclc035 += 1;
  #           }
  #       }
  #   }
  #   $bib_sth->finish();

  #   print OUTFILE "      <datafield ind1=' ' ind2=' ' tag='955'>\n";
  #   print OUTFILE "        <subfield code='b'>$barcode</subfield>\n";
  #   if ($volume) {
  #       print OUTFILE "        <subfield code='v'>$volume</subfield>\n";
  #   }
  #   print OUTFILE "      </datafield>\n";

  #   #Check counts of certain fields and write warnings accordingly.
  #   if ($oclc035 == 0) {
  #       # If there is no OCLC 035, determine whether 001 is an OCLC number and provide it if possible.
  #       my $oclcnum;

  #       # If 001 consists only of digits...
  #       if ( $orig001 =~ m/^\d+$/ ) {
  #           #  ...and 003 is blank, then 001 is an OCLC number
  #           if ( $orig003 =~ m/^$/ ) {
  #               $oclcnum = $orig001;
  #           } else {           #  ...and 003 is not blank, then if...
  #               #   ...003 is OCoLC, 001 is OCLC number
  #               if ( $orig003 =~ m/OCoLC/i ) {
  #                   $oclcnum = $orig001;
  #               }
  #               #   ...003 is not OCoLC, 001 is NOT OCLC number
  #           }
  #       } else {        # If 001 has characters that are not digits...
  #           #  ...and 003 is blank, 001 is NOT OCLC number
  #           #  ...and 003 is not blank, then if...
  #           unless ( $orig003 =~ m/^$/ ) {
  #               #   ...003 is OCoLC, remove non-digits and call it OCLC number
  #               if ( $orig003 =~ m/OCoLC/i ) {
  #                   $orig001 =~ s/\D//g;
  #                   $oclcnum = $orig001;
  #               }
  #               #   ...003 is not OCoLC, 001 is NOT OCLC number
  #           }
  #       }

  #       if ( $oclcnum ) {
  #           print OUTFILE "      <datafield ind1=' ' ind2=' ' tag='035'>\n";
  #           print OUTFILE "        <subfield code='a'>(OCoLC)$oclcnum</subfield>\n";
  #           print OUTFILE "      </datafield>\n";
  #       } else {
  #           print WARN "$bnum_full\tThis bib does not contain an 035 field with an OCLC number. Report to cataloging staff to have an OCLC number added in an 035 field.\n";
  #           $warning_ct += 1;
  #       }
  #   } elsif ($oclc035 > 1) {
  #       print WARN "$bnum_full\tThis bib contains more than 035 field with an OCLC number. Report to cataloging staff to have an OCLC numbers checked/corrected.\n";
  #       $warning_ct += 1;
  #   }

  #   if ($ct008 == 0) {
  #       print WARN "$bnum_full\tThis bib does not contain an 008 field, which is a required field. Report to cataloging staff to fix 008 field.\n";
  #       $warning_ct += 1;
  #   }

  #   if ($ct245 > 1) {
  #       print WARN "$bnum_full\tThis bib contains more than one 245 field, which is a non-repeatable field. Report to cataloging staff to fix.\n";
  #       $warning_ct += 1;
  #   }

  #   if ($ct245ak == 0) {
  #       print WARN "$bnum_full\tThis bib does not contain a subfield a or k in the 245. Report to cataloging staff to fix.\n";
  #       $warning_ct += 1;
  #   }

    print OUTFILE "  </record>\n";
}                               #end RECORD


close(INFILE);

$dbh->disconnect();

print OUTFILE "</collection>";
close(OUTFILE);
close(WARNFILE);

if ( $warning_ct > 0 ) {
    print "Bibliographic metadata compilation failed with $warning_ct errors.\n";
}

sub escape_xml_reserved() {
    my $data = $_[0];
    $data =~ s/&/&amp;/g;
    $data =~ s/</&lt;/g;
    $data =~ s/>/$gt;/g;
    $data =~ s/"/&quot;/g;
    $data =~ s/'/&apos;/g;
    return $data;
}

# Gets rid of white space...
sub trim{
    $incoming = $_[0];
    $incoming =~ s/^\s+//g;
    $incoming =~ s/\s+$//g;
    return $incoming;
}

sub mail_error(){
    $message_addendum = $_[0];
    $message .= $message_addendum;
    $message .= "Compiled bib file not written\n\n";
    print $message;
    exit;
}
exit;
