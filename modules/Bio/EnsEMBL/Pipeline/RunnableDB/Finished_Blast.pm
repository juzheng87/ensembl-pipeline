#
# You may distribute this module under the same terms as perl itself
#
# POD documentation - main docs before the code

=pod 

=head1 NAME

Bio::EnsEMBL::Pipeline::RunnableDB::Blast

=head1 SYNOPSIS

my $db      = Bio::EnsEMBL::DBLoader->new($locator);
my $blast   = Bio::EnsEMBL::Pipeline::RunnableDB::Blast->new ( 
                                                    -db         => $db,
                                                    -input_id   => $input_id
                                                    -analysis   => $analysis );
$blast->fetch_input();
$blast->run();
$blast->output();
$blast->write_output(); #writes to DB

=head1 DESCRIPTION

This object wraps Bio::EnsEMBL::Pipeline::Runnable::Blast to add
functionality for reading and writing to databases.
The appropriate Bio::EnsEMBL::Analysis object must be passed for
extraction of appropriate parameters. A Bio::EnsEMBL::Pipeline::DBSQL::Obj is
required for databse access.

=head1 CONTACT

Describe contact details here

=head1 APPENDIX

The rest of the documentation details each of the object methods. 
Internal methods are usually preceded with a _

=cut

package Bio::EnsEMBL::Pipeline::RunnableDB::Finished_Blast;

use strict;
use Bio::EnsEMBL::Pipeline::RunnableDB;
use Bio::EnsEMBL::Pipeline::Runnable::Finished_Blast;
use Bio::EnsEMBL::Pipeline::SeqFetcher::Finished_Pfetch;
use Bio::EnsEMBL::Pipeline::Config::Blast;
use Bio::EnsEMBL::Pipeline::Config::General;
use vars qw(@ISA);

@ISA = qw (Bio::EnsEMBL::Pipeline::RunnableDB);

my %UNGAPPED;
my %UNMASKED;

foreach my $db (@$DB_CONFIG) {
    my (   $name,         $ungapped,         $unmasked )
    = ($db->{'name'}, $db->{'ungapped'}, $db->{min_unmasked});
    
    if($db && $name){
        $UNGAPPED{$name} = $ungapped;
        $UNMASKED{$name} = $unmasked;
        }else{
        my($p, $f, $l) = caller;
        warn("either db ".$db." or name ".$name." isn't defined so can't work $f:$l\n");
    }
}

=head2 fetch_input

    Title   :   fetch_input
    Usage   :   $self->fetch_input
    Function:   Fetches input data for repeatmasker from the database
    Returns :   none
    Args    :   none

=cut

sub fetch_input {
    my($self) = @_;
    my $genseq;
   
    $self->throw("No input id") unless defined($self->input_id);
    print STDERR "INPUT ID: " . $self->input_id . "\n";    

    my $contig = $self->db->get_RawContigAdaptor->fetch_by_name($self->input_id);
    $genseq    = $contig->get_repeatmasked_seq($PIPELINE_REPEAT_MASKING,$SOFT_MASKING) or $self->throw("Unable to fetch contig");
    $self->query($genseq || $contig);
    
    my $seq = $self->query->seq;
    
    if ($seq =~ /[CATG]{3}/) {
        $self->input_is_void(0);
        #$self->check_with_seg($self->query);
    } else {
        $self->input_is_void(1);
        $self->warn("Need at least 3 nucleotides");
    }
    
    my $ungapped;
    if($UNGAPPED{$self->analysis->db_file}){
        $ungapped = 1;
        } else {
        $ungapped = undef;
    }
    my $runnable = Bio::EnsEMBL::Pipeline::Runnable::Finished_Blast->new(-query          => $self->query,
        -database       => $self->analysis->db_file,
        -program        => $self->analysis->program,
        -options        => $self->analysis->parameters,
        -threshold_type => 'PVALUE',
        -threshold      => 1,
        -ungapped       => $ungapped,
    );
    
    $self->runnable($runnable);

    return 1;
}

sub check_with_seg{
    my ($self, $seqObj_to_test) = @_;

    warn "need a Bio::Seq Obj" unless $seqObj_to_test;

    my ($filename) = $self->_createfiles('/tmp',[qw(seg_checking)]);
    my $file = Bio::SeqIO->new(-file   => ">$filename", 
                               -format => 'Fasta') 
        or $self->throw("Can't create Bio::SeqIO $filename $!");
    my $translated = $seqObj_to_test->translate;
    #warn "************************************************************";
    #warn $translated->seq;
    #warn "************************************************************";
    $file->write_seq($translated);
    
    my $seg_cmd = "nseg $filename -x";
    my $seg = Bio::SeqIO->new(-file   => "$seg_cmd |",
                              -format => 'Fasta')
        or $self->throw("Can't create Bio::SeqIO $seg_cmd $!");
    my $seq;
    eval{
        $seq = $seg->next_seq->seq;
    };
    unlink($filename);
    if($@){
        $self->throw("There was a problem with SEG masking.\nI tried to '$seg_cmd'");
    }
    #warn "************************************************************";
    #warn $seq;
    #warn "************************************************************";
    if($seq =~ /[CATG]{3}/i){
        $self->input_is_void(0);
    }else{
        $self->input_is_void(1);
        $self->warn("Need at least 3 nucleotides after SEG filtering");
    }
    
}
sub _createfiles {
    my ($self, $dirname, $filenames) = @_;
    
    my $unique = {};
    $unique    = { map { $_, $unique->{$_}++ } @$filenames };
    my @files  = ();

    $dirname ||= '/tmp';
    $dirname   =~ s!(\S+)/$!$1!;

    foreach my $file(@$filenames){
        if($unique->{$file}){
            #name not unique add random
            $file .= ".$$.".int(rand(200));
            push(@files, "$dirname/$file");
        }else{
            #name was unique just add it
            push(@files, "$dirname/$file.$$");
        }
    }

    return @files;
}
=head2 run

    Title   :   run
    Usage   :   $self->run();
    Function:   Runs Bio::EnsEMBL::Pipeline::Runnable::xxxx->run()
    Returns :   none
    Args    :   none

=cut

sub run {
    my ($self) = @_;
    
    foreach my $runnable ($self->runnable) {
        
        $self->throw("Runnable module not set") unless ($runnable);
        
        # Not sure about this
        $self->throw("Input not fetched")       unless ($self->query);
        eval{
            $runnable->run();
        };
        if($@){
            chomp $@;
            $self->failing_job_status($1) 
                if $@ =~ /^\"([A-Z_]{1,40})\"$/i; # only match '"ABC_DEFGH"' and not all possible throws
            $self->throw("$@");
        }
        my $db_version = $runnable->db_version_searched if $runnable->can('db_version_searched');
        $self->db_version_searched($db_version);
        if ( my @output = $runnable->output ) {
            my $dbobj      = $self->db;
            my $seqfetcher = Bio::EnsEMBL::Pipeline::SeqFetcher::Finished_Pfetch->new;
            my %ids        = map { $_->hseqname, 1 } @output;
            $seqfetcher->write_descriptions( $dbobj, keys(%ids) );
        }
    }
    return 1;
}



sub db_version_searched{
    my $self = shift;
    $self->{'_db_version_searched'} = shift if @_;
    return $self->{'_db_version_searched'};
}

1;
