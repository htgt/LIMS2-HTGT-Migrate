#!/usr/bin/env perl

use strict;
use warnings FATAL => 'all';

use Getopt::Long;
use Const::Fast;
use Log::Log4perl qw( :levels );
use DateTime::Format::ISO8601;
use Pod::Usage;

const my %CLASS_FOR => (
    design => 'LIMS2::HTGT::Migrate::PlateData::Design',
    pcs    => 'LIMS2::HTGT::Migrate::PlateData::PCS',
    vtp    => 'LIMS2::HTGT::Migrate::PlateData::VTP',
);

my $log_level = $WARN;

GetOptions(
    'debug'           => sub { $log_level => $DEBUG },
    'verbose'         => sub { $log_level => $INFO },
    'type=s'          => \my $plate_type,
    'limit=i'         => \my $limit,
    'created-after=s' => \my $created_after,    
    'plate_name=s'    => \my @plate_names,
) or pod2usage(2);

pod2usage( "Plate type must be specified" )
    unless defined $plate_type;

my $class = $CLASS_FOR{$plate_type}
    or pod2usage( "Plate type '$plate_type' is not recognized" );

eval "require $class"
    or die "Failed to load $class: $@";

if ( defined $created_after ) {
    $created_after = DateTime::Format::ISO8601->parse_datetime( $created_after );
}

Log::Log4perl->easy_init(
    {
        level  => $log_level,
        layout => '%d %p %x %m%n'
    }
);

my $worker = $class->new( limit => $limit, created_after => $created_after, plate_names => \@plate_names );

$worker->dump_plate_data();

__END__

=pod

=head1 NAME

dump_plate_data.pl

=head1 SYNOPSIS

  dump_plate_data.pl [OPTIONS] --type=PLATE_TYPE

  Options:

    --debug
    --verbose
    --limit=N
    --created-after=DATE


=cut
