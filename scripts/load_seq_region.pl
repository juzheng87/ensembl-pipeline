#!/usr/local/ensembl/bin/perl -w

=head1 NAME

load_seq_region.pl

=head1 SYNOPSIS

  load_seq_region.pl <DB CONNECT OPTIONS> \
    { --dbname <databse name> | --regex <?> } \
    <COORDINATE SYSTEM OPTIONS> \
    { -fasta file <my.fa> | -agp_file {my.agp} }

=head1 DESCRIPTION

This script can do three things:

1) Use entries in a FASTA file to load a set of seq_regions into the
   seq_region table.

2) The sequence from the FASTA file can be optionally added to the dna
   table.

3) It can load seq_regions that represent the objects in an AGP file.

In all cases, appropriate (configurable) entries will be added to the
coord_system_table.


Here are example usages:

This would load the *sequences* in the given FASTA file into the
database under a coord system called contig:

./load_seq_region.pl \
  -dbhost host -dbuser user -dbname my_db -dbpass **** \
  -coord_system_name contig -rank 4 -sequence_level \
  -fasta_file sequence.fa


This would just load seq_regions to represent the entries in this
FASTA file:

./load_seq_region.pl \
  -dbhost host -dbuser user -dbname my_db -dbpass **** \
  -coord_system_name clone -rank 3 \
  -fasta_file clone.fa


This will load the assembled pieces from the AGP file into the
seq_region table. 

./load_seq_region \
  -dbhost host -dbuser user -dbname my_db -dbpass **** \
  -coord_system_name chromosome -rank 1 \
  -agp_file genome.agp



=head1 OPTIONS

    DB CONNECT OPTIONS:
    -dbhost    Host name for the database
    -dbname    For RDBs, what name to connect to
    -dbuser    For RDBs, what username to connect as
    -dbpass    For RDBs, what password to use


    COORDINATE SYSTEM OPTIONS:

    -coord_system_name
               The name of the coordinate system being stored.

    -coord_system_version
               The version of the coordinate system being stored.

    -default_version
               Flag to denote that this version is the default version
               of the coordinate system.

    -rank      The rank of the coordinate system. The highest
               coordinate system should have a rank of 1 (e.g. the
               chromosome coordinate system). The nth highest should
               have a rank of n. There can only be one coordinate
               system for a given rank.


    -sequence_level
               Flag to denete that this coordinate system is a
               'sequence level'. This means that sequence will be
               stored from the FASTA file in the dna table. This
               option isn't valid for an agp_file.


    OTHER OPTIONS:

    -agp_file   The name of the agp file to be parsed.

    -fasta_file The name of the fasta file to be parsed. Without the
                presence of the -sequence_level option the sequence
                will not be stored.

    -verbose    Prints the name which is going to be used can be switched
                off with -noverbose

    -help     Displays this documentation with PERLDOC.

=cut

use strict;
use Bio::EnsEMBL::DBSQL::DBAdaptor;
use Bio::EnsEMBL::Slice;
use Bio::EnsEMBL::CoordSystem;
use Bio::EnsEMBL::Utils::Exception qw(throw warning);

use Bio::SeqIO;

use Getopt::Long;

my $dbhost   = '';
my $port   = '';
my $dbname = '';
my $dbuser = '';
my $dbpass = '';
my $help;
my $cs_name;
my $cs_version;
my $default = 0;
my $sequence_level = 0;
my $agp;
my $fasta;
my $rank;
my $verbose = 0;
my $regex;
my $name_file;

&GetOptions(
            'dbhost|host:s' => \$dbhost,
            'dbport|port:n' => \$port,
            'dbname|D:s'    => \$dbname,
            'dbuser|user:s' => \$dbuser,
            'dbpass|pass:s' => \$dbpass,

            'coord_system_name:s'    => \$cs_name,
            'coord_system_version:s' => \$cs_version,
            'rank:i'                 => \$rank,
            'sequence_level!'        => \$sequence_level,
            'default_version!'       => \$default,

            'agp_file:s'   => \$agp,
            'fasta_file:s' => \$fasta,

            'regex:s'     => \$regex,
            'name_file:s' => \$name_file,

            'verbose!' => \$verbose,
            'h|help'   => \$help,
           ) or ($help = 1);

if(!$dbhost || !$dbuser || !$dbname || !$dbpass){
  print STDERR "Can't store sequence without database details\n";
  print STDERR "-dbhost $dbhost -dbuser $dbuser -dbname $dbname ".
    " -dbpass $dbpass\n";
  $help = 1;
}
if(!$cs_name || (!$fasta  && !$agp)){
  print STDERR "Need coord_system_name and fasta/agp file to beable to run\n";
  print STDERR "-coord_system_name $cs_name -fasta_file $fasta -agp_file $agp\n";
  $help = 1;
}
if($agp && $sequence_level){
  print STDERR ("Can't use an agp file $agp to store a ".
                "sequence level coordinate system ".$cs_name."\n");
  $help = 1;
}
if(!$rank) {
  print STDERR "A rank for the coordinate system must be specified " .
    "with the -rank argument\n";
    $help = 1;
}

if ($help) {
    exec('perldoc', $0);
}



my $db = Bio::EnsEMBL::DBSQL::DBAdaptor->new(
    -dbname => $dbname,
    -host   => $dbhost,
    -user   => $dbuser,
    -port   => $port,
    -pass   => $dbpass
);


my $csa = $db->get_CoordSystemAdaptor();

my $cs;
eval{
  $cs = $csa->fetch_by_name($cs_name, $cs_version);
};
if(!$cs){
  $cs = Bio::EnsEMBL::CoordSystem->new
    (
     -NAME            => $cs_name,
     -VERSION         => $cs_version,
     -DEFAULT         => $default,
     -SEQUENCE_LEVEL  => $sequence_level,
     -RANK            => $rank
    );
$csa->store($cs);
}

my $sa  = $db->get_SliceAdaptor();

my %acc_to_name;

if ($name_file){
  open(NF, $name_file) or throw("Can't open ".$name_file." ".$!);
  while(<NF>){   
    chomp;
    my @name_values = split(/\s+/,$_);
    $acc_to_name{$name_values[1]}=$name_values[0];

  }
}


if($fasta){
  my $count_ambiguous_bases = &parse_fasta($fasta, $cs, $sa, $sequence_level,$regex,);
  if ($count_ambiguous_bases) {
    throw("All sequences has loaded, but $count_ambiguous_bases slices have ambiguous bases - see warnings. Please change all ambiguous bases (RYKMSWBDHV) to N.");
  }
}

if($agp){
  &parse_agp($agp, $cs, $sa,%acc_to_name);
}

sub parse_fasta{
  my ($filename, $cs, $sa, $store_seq,$regex,) = @_;
  my $have_ambiguous_bases = 0;

  my $seqio = new Bio::SeqIO(
                             -format=>'Fasta',
                             -file=>$filename
                            );
  
  while ( my $seq = $seqio->next_seq ) {
    
    #NOTE, the code used to generate the name very much depends on the 
    #format of your fasta headers and what id you want to use
    #In this case we use the first word of the sequences description as
    #parseed by SeqIO but you may want the id or you may want to use a
    #regular experssion to get the sequence you will need to check what 
    #this will produce, if you have checked your ids and you know what
    #you are getting you may want to comment out the warning about this
    #print STDERR "id ".$seq->id." ".$seq->desc."\n";
    #my @values = split /\s+/, $seq->desc;
    #my @name_vals = split /\|/, $seq->id;
    my $name = $seq->id;

    #my $name = $name_vals[3]; 
       
    if ($regex) {
      ($name) = $name =~ /$regex/;
    }
    warning("You are going to store with name ".$name." are you sure ".
            "this is what you wanted") if($verbose);
    my $slice = &make_slice($name, 1, $seq->length, $seq->length, 1, $cs);
    if($store_seq){
      # check that we don't have ambiguous bases in the DNA sequence
      # we are only allowed to load ATGCN
      if ($seq->seq =~ /[^ACGTN]+/i) {
        $have_ambiguous_bases++;
        warning("Slice ".$name." has at least one non-ATGCN (RYKMSWBDHV) base. Please change to N.");
      }
      $sa->store($slice, \$seq->seq);
    }else{
      $sa->store($slice);
    }
  }
  return $have_ambiguous_bases;
}


sub parse_agp{
  my ($agp_file, $cs, $sa,%acc_to_name) = @_;
  my %end_value;
  open(FH, $agp_file) or throw("Can't open ".$agp_file." ".$!);
 LINE:while(<FH>){   
    chomp;
    next if /^\#/;

    #GL000001.1      1       615     1       F       AP006221.1      36117   36731   -
    #GL000001.1      616     167417  2       F       AL627309.15     103     166904  +
    #GL000001.1      167418  217417  3       N       50000   clone   yes

    #cb25.fpc4250	119836	151061	13	W	c004100191.Contig2	1	31226	+
    #cb25.fpc4250	151062	152023	14	N	962	telomere	yes
    my @values = split;
    #if($values[4] eq 'N'){
    #  next LINE; 
    #}
    my $initial_name = $values[0];
   
    # remove the 'chr' string if it exists
    if ($initial_name =~ /^chr(\S+)/) {
      $initial_name = $1;
    }


    my $name;

    if ($acc_to_name{$initial_name}){
      $name = $acc_to_name{$initial_name};
    }else{
      $name =$initial_name;
    }

    print "Name: ",$name,"\n";
    
    my $end = $values[2];
    if(!$end_value{$name}){
      $end_value{$name} = $end;
    }else{
      if($end > $end_value{$name}){
        $end_value{$name} = $end;
      }
    }
  }
  foreach my $name(keys(%end_value)){
    my $end = $end_value{$name};
    my $slice = &make_slice($name, 1, $end, $end, 1, $cs);
    $sa->store($slice);
  }
  
  close(FH) or throw("Can't close ".$agp_file);
}

sub make_slice{
  my ($name, $start, $end, $length, $strand, $coordinate_system) = @_;

  my $slice = Bio::EnsEMBL::Slice->new
      (
       -seq_region_name   => $name,
       -start             => $start,
       -end               => $end,
       -seq_region_length => $length,
       -strand            => $strand,
       -coord_system      => $coordinate_system,
      );
  return $slice;
}


