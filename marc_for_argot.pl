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
    if ($bnum =~ m/^#/) {
        next RECORD
    }
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
    }                           #end CTRLFIELD

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
    }                           #end VCTRLFIELD

    #Set up to grab the rest of the fields and process them
    my $bib_sql = "select marc_tag, field_content, marc_ind1, marc_ind2
                    from sierra_view.varfield
                    where record_id = $bib_id
                    and marc_tag NOT IN ('001', '003', '005')
                    order by marc_tag, occ_num";

    my $bib_sth = $dbh->prepare($bib_sql);
    $bib_sth->execute();
    my ($marc_tag, $rec_data, $ind1, $ind2) = ('', '', '', '');
    $bib_sth->bind_columns (undef, \$marc_tag, \$rec_data, \$ind1, \$ind2 );

  FIELD: while ($bib_sth->fetch()) {
        #Escape XML-reserved characters in the data
        if ($rec_data =~ m/[<>&"']/) {
            $rec_data = escape_xml_reserved ($rec_data);
        }

        print OUTFILE "      <datafield ind1='$ind1' ind2='$ind2' tag='$marc_tag'>\n";
        if ($rec_data =~ m/^[^|]/) {
            $rec_data = '|a' . $rec_data;
        }
        my @subfields = split /\|/, "$rec_data";
        # need to get ordered list of delimiters in fields so we can throw errors
        #  if some fields don't start with (or contain) required subfields
        my @delimiters = ();
        foreach my $subfield (@subfields) {
            if ($subfield) {
                my $delimiter = substr ($subfield, 0, 1);
                my $data = trim (substr ($subfield, 1));
                print OUTFILE "        <subfield code='$delimiter'>$data</subfield>\n";
                push @delimiters, $delimiter;
            }
        }
        print OUTFILE "      </datafield>\n";
    }

    $bib_sth->finish();

    #Get counts of unsuppressed item, holdings, and order records
    my (@items, @holdings, @orders);

    #-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
    # ITEMS
    #-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
    my $item_ct_sql = "SELECT
                         lr.item_record_id
                       FROM
                         sierra_view.bib_record_item_record_link lr,
                         sierra_view.item_record i
                       WHERE
                         lr.bib_record_id = $bib_id
                       AND lr.item_record_id = i.record_id
                       AND i.icode2 != 'n'
                       ORDER BY
                         lr.items_display_order ASC";
    my $item_ct_sth = $dbh->prepare($item_ct_sql);
    $item_ct_sth->execute();
    $item_ct_sth->bind_columns (undef, \$item_id );

    while ($item_ct_sth->fetch()) {
        push @items, $item_id;
    }
    $item_ct_sth->finish();
    my $item_ct = scalar @items;

    #-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
    # HOLDINGS
    #-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
    my $holdings_ct_sql = "SELECT
                             lr.holding_record_id
                           FROM
                             sierra_view.bib_record_holding_record_link lr,
                             sierra_view.holding_record h
                           WHERE
                             lr.bib_record_id = $bib_id
                           AND lr.holding_record_id = h.record_id
                           AND h.scode2 != 'n'
                           ORDER BY
                             lr.holdings_display_order ASC";
    my $holdings_ct_sth = $dbh->prepare($holdings_ct_sql);
    $holdings_ct_sth->execute();
    my ($holdings_ct);
    $holdings_ct_sth->bind_columns (undef, \$holding_id );
    while ($holdings_ct_sth->fetch()) {
        push @holdings, $holding_id
    }
    $holdings_ct_sth->finish();
    my $holding_ct = scalar @holdings;

    #-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
    # ORDERS - only if there are no unsuppressed items
    #-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
    if ($item_ct == 0) {
        my $orders_ct_sql = "SELECT
                             lr.order_record_id
                           FROM
                             sierra_view.bib_record_order_record_link lr,
                             sierra_view.order_record h
                           WHERE
                             lr.bib_record_id = $bib_id
                           AND lr.order_record_id = h.record_id
                           AND h.ocode3 != 'n'
                           ORDER BY
                             lr.orders_display_order ASC";
        my $orders_ct_sth = $dbh->prepare($orders_ct_sql);
        $orders_ct_sth->execute();
        my ($orders_ct);
        $orders_ct_sth->bind_columns (undef, \$order_id );
        while ($orders_ct_sth->fetch()) {
            push @orders, $order_id
        }
        $orders_ct_sth->finish();
    }
    my $order_ct = scalar @orders;

    if ($testing) {
        print "Attached items: $item_ct; Attached holdings: $holding_ct; Attached orders: $order_ct\n";
    }

    # #-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
    # # PROCESS ITEM RECORD DATA
    # #-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
    # if ($item_ct > 0) {
    #     foreach my $item_id (@items) {
    #         my $item_sql = "SELECT
    #                        (SELECT 'i' || rm.record_num from sierra_view.record_metadata rm
    #                          where rm.id = i.record_id) AS inum,
    #                        i.copy_num,
    #                        i.location_code,
    #                        i.item_status_code,
    #                        TO_CHAR(c.due_gmt, 'YYYYMMDD'),
    #                        i.checkout_total,
    #                        i.itype_code_num
    #                      FROM
    #                        sierra_view.item_record i
    #                        LEFT OUTER JOIN sierra_view.checkout c
    #                          ON i.record_id = c.item_record_id
    #                      WHERE
    #                      i.record_id = $item_id";
    #         my $item_sth = $dbh->prepare($item_sql);
    #         $item_sth->execute();

    #         my ($item_num, $copy_num, $location, $status, $due_date, $tot_chkout, $i_type);
    #         $item_sth->bind_columns (undef, \$item_num, \$copy_num, \$location, \$status, \$due_date, \$tot_chkout, \$i_type );

    #       ITEMREC: while ($item_sth->fetch()) {
    #             print OUTFILE "      <datafield ind1='9' ind2='1' tag='999'>\n";
    #             print OUTFILE "        <subfield code='i'>$item_num</subfield>\n";
    #             print OUTFILE "        <subfield code='l'>$location</subfield>\n";
    #             print OUTFILE "        <subfield code='s'>$status</subfield>\n";
    #             print OUTFILE "        <subfield code='t'>$i_type</subfield>\n";
    #             print OUTFILE "        <subfield code='c'>$copy_num</subfield>\n";
    #             print OUTFILE "        <subfield code='o'>$tot_chkout</subfield>\n";
    #             if ($due_date ne '') {
    #                 print OUTFILE "        <subfield code='d'>$due_date</subfield>\n";
    #             }

    #             #Get variable data for items
    #             my @ivarfields;
    #             my $ivar_sql = "SELECT
    #                                varfield_type_code,
    #                                marc_tag,
    #                                field_content
    #                              FROM
    #                                sierra_view.varfield
    #                              WHERE
    #                                record_id = $item_id
    #                              AND varfield_type_code IN ('b', 'c', 'v', 'z')
    #                              ORDER BY varfield_type_code, occ_num ASC";
    #             my $ivar_sth = $dbh->prepare($ivar_sql);
    #             $ivar_sth->execute();
    #             my ($vtype, $mtag, $data);
    #             $ivar_sth->bind_columns (undef, \$vtype, \$mtag, \$data );
    #             while ($ivar_sth->fetch()) {
    #                 my $catch = "$vtype\t$mtag\t$data";
    #                 push @ivarfields, $catch;
    #             }
    #             $ivar_sth->finish();
    #             if (scalar @ivarfields > 0) {

    #                 foreach my $ivar (@ivarfields) {
    #                     my @broken = split /\t/, $ivar;
    #                     my $code = $broken[0];
    #                     my $tag = $broken[1];
    #                     my $data = $broken[2];
    #                     if ($data =~ m/[<>&"']/) {
    #                         $data = escape_xml_reserved($data);
    #                     }

    #                     #barcode
    #                     if ($code eq 'b') {
    #                         print OUTFILE "        <subfield code='b'>$data</subfield>\n";
    #                     } elsif ($code eq 'c') {
    #                         #call number
    #                         print OUTFILE "        <subfield code='p'>$tag</subfield>\n";
    #                         $data = trim($data);
    #                         print OUTFILE "        <subfield code='q'>$data</subfield>\n";
    #                     } elsif ($code eq 'v') {
    #                         print OUTFILE "        <subfield code='v'>$data</subfield>\n";
    #                     } elsif ($code eq 'z') {
    #                         print OUTFILE "        <subfield code='n'>$data</subfield>\n";
    #                     }
    #                 }
    #             }
    #             print OUTFILE "      </datafield>\n";
    #         }                   #END ITEMREC
    #     }
    # }                           #END processing of item data

    #-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
    # PROCESS HOLDINGS RECORD DATA
    #-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
    if ($holding_ct > 0) {
        my $hold_sql;
        foreach my $holding_id (@holdings) {
            $hold_sql = "SELECT
                           lr.holding_record_id AS hrec_id,
                           'c' || rm.record_num AS hnum,
                           hl.location_code AS location,
                          (SELECT COUNT(*) FROM sierra_view.holding_record_card WHERE holding_record_id = lr.holding_record_id) AS hcard_ct
                         FROM
                           sierra_view.bib_record_holding_record_link lr
                         INNER JOIN sierra_view.holding_record_location hl
                           ON lr.holding_record_id = hl.holding_record_id
                         INNER JOIN sierra_view.holding_record h
                           ON lr.holding_record_id = h.id
                         INNER JOIN sierra_view.record_metadata rm
                           ON lr.holding_record_id = rm.id
                         AND h.scode2 != 'n'
                         WHERE
                           lr.bib_record_id = '$bib_id'
                         ORDER BY lr.holdings_display_order ASC";
        }
        my $hold_sth = $dbh->prepare($hold_sql);
        $hold_sth->execute();

        my ($hrec_id, $hnum, $h_location_code, $hcard_ct);
        $hold_sth->bind_columns (undef, \$hrec_id, \$hnum, \$h_location_code, \$hcard_ct);

      HOLDINGSREC: while ($hold_sth->fetch()) {
            print OUTFILE "      <datafield ind1='9' ind2='2' tag='999'>\n";
            print OUTFILE "        <subfield code='a'>$hnum</subfield>\n";
            print OUTFILE "        <subfield code='b'>$h_location_code</subfield>\n";
            print OUTFILE "        <subfield code='c'>$hcard_ct</subfield>\n";
            print OUTFILE "      </datafield>\n";

            my $hfield_sql = "SELECT
                                marc_tag,
                                field_content,
                                varfield_type_code
                              FROM
                                sierra_view.varfield
                              WHERE
                                record_id = '$hrec_id'
                                and ( marc_tag = '852'
                                      OR
                                      marc_tag IN ('863', '864', '865', '866', '867', '868') AND varfield_type_code = 'h'
                                    )
                              ORDER BY varfield_type_code, occ_num ASC";

            my $hfield_sth = $dbh->prepare($hfield_sql);
            $hfield_sth->execute();

            my ($h_marc_tag, $h_rec_data, $h_iii_tag);
            $hfield_sth->bind_columns (undef, \$h_marc_tag, \$h_rec_data, \$h_iii_tag);

            while ($hfield_sth->fetch()) {
                if (($h_marc_tag =~ m/86[36]/ && $h_iii_tag eq 'h') || $h_marc_tag =~ m/852|86[4578]/) {
                    print OUTFILE "      <datafield ind1='9' ind2='3' tag='999'>\n";
                    print OUTFILE "        <subfield code='0'>$hnum</subfield>\n";
                    print OUTFILE "        <subfield code='2'>$h_marc_tag</subfield>\n";
                    print OUTFILE "        <subfield code='3'>$h_iii_tag</subfield>\n";

                    @h_subfields = split /\|/, "$h_rec_data";
                    foreach $h_subfield (@h_subfields) {
                        if ($h_subfield ne "" ) {
                            $h_delimiter = substr ($h_subfield, 0, 1);
                            $h_data = substr ($h_subfield, 1);
                            if ($h_data =~ m/[<>&"']/) {
                                $h_data = escape_xml_reserved($h_data);
                            }

                            print OUTFILE "        <subfield code='$h_delimiter'>$h_data</subfield>\n";
                        }
                    }
                    print OUTFILE "      </datafield>\n";
                }
            }
        }                       #end HOLDINGSREC
    }
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
    $data =~ s/>/&gt;/g;
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
