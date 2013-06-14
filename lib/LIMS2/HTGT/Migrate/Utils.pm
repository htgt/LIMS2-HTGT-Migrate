package LIMS2::HTGT::Migrate::Utils;

use strict;
use warnings FATAL => 'all';

use Sub::Exporter -setup => {
    exports => [
        qw(
              htgt_plate_types
              lims2_plate_type
              format_well_name
              format_bac_library
              is_consistent_design_instance
              trim
              parse_oracle_date
              sponsor2pipeline
              canonical_username
              canonical_datetime
      )
    ]
};

use Scalar::Util qw( blessed );
use Try::Tiny;
use Log::Log4perl qw( :easy );
use Const::Fast;
use YAML::Any;

our $USERS_YAML = '/var/tmp/users.yaml';

{
    
    const my %PLATE_TYPE_FOR => (
        DESIGN => 'DESIGN',
        EP     => 'EP',
        EPD    => 'EPD',
        FP     => 'FP',
        GR     => 'PGS',
        GRD    => 'PGS',
        GRQ    => 'DNA',
        PC     => 'PCS',
        PCS    => 'PCS',
        PGD    => 'PGS',
        PGG    => 'DNA',
        REPD   => 'EPD',
    );
    
    sub htgt_plate_types {
        my $type = shift;

        [ grep { $PLATE_TYPE_FOR{$_} eq $type } keys %PLATE_TYPE_FOR ];
    }

    sub lims2_plate_type {
        my $type = shift;

        return $PLATE_TYPE_FOR{$type};
    }
}

{
    const my %PIPELINE_FOR => (
        'KOMP'             => 'komp_csd',
        'EUCOMM'           => 'eucomm',
        'EUCOMM-Tools'     => 'eucomm_tools',
        'EUCOMM-Tools-Cre' => 'eucomm_tools_cre',
        'SWITCH'           => 'switch',
        'REGENERON'        => undef,
        'EUTRACC'          => undef,
        'NORCOMM'          => undef,
        'MGP'              => undef,
        'MGP-Bespoke'      => undef,
        'TPP'              => undef,
    );

    sub sponsor2pipeline {
        my $sponsor = shift;

        my $pipeline = $PIPELINE_FOR{$sponsor};

        unless ( defined $pipeline ) {
            WARN "Unrecognized sponsor: $sponsor";
            return undef;
        }
        
        return $pipeline;
    }
}

sub format_well_name {
    my $well_name = shift;

    uc substr $well_name, -3;
}

sub format_bac_library {
    my $str = shift;

    if ( $str eq '129' ) {
        return $str;
    }
    elsif ( $str eq 'black6' or $str eq 'black6_M37' or $str eq 'black6_GRCm38' ) {
        return 'black6';
    }
    else {
        die "Unrecognized bac_library: '$str'";
    }
}

sub is_consistent_design_instance {
    my ( $well, $parent_well ) = @_;

    defined $well
        and defined $parent_well
            and defined $well->design_instance_id
                and defined $parent_well->design_instance_id
                    and $well->design_instance_id == $parent_well->design_instance_id;
}

sub parse_oracle_date {
    my ( $maybe_date ) = @_;

    if ( ! defined $maybe_date ) {
        return;
    }    
    elsif ( ref $maybe_date ) {
        return $maybe_date;
    }

    my $date = try {
        DateTime::Format::Oracle->parse_timestamp( $maybe_date );
    };

    return $date if defined $date;

    $date = try {
        DateTime::Format::Oracle->parse_datetime( $maybe_date );
    };        

    return $date;
}

sub canonical_datetime {
    my $date = shift;

    my $datetime = parse_oracle_date( $date )
        or return undef;

    return $datetime->iso8601;
}

sub trim {
    my ( $str ) = @_;

    $str = '' unless defined $str;
    
    for ( $str ) {
        s/^\s+//;
        s/\s+$//;
    }
    
    return $str;
}

{
    my $canon_user;

    sub canonical_username {
        my $name = shift;

        unless ( $canon_user ) {
            my %canon_user;
            for my $u ( YAML::Any::LoadFile( $USERS_YAML ) ) {
                $canon_user{ $u->{user_name} } = lc( $u->{map_to} || $u->{user_name} );
            }
            $canon_user = \%canon_user;
        }

        return lc( $canon_user->{$name} || $name );
    }
}

1;
