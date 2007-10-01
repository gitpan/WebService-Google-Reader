#!/usr/bin/env perl
use strict;
use warnings;
use WebService::Google::Reader;

my $reader = WebService::Google::Reader->new(
    username => $ENV{GOOGLE_USERNAME},
    password => $ENV{GOOGLE_PASSWORD},
);

my $feed = $reader->feed( state => 'reading-list', count => 50 )
    or die $reader->error;

do {
    for my $entry ( $feed->entries ) {
        print $entry->title, "\n";
        print $entry->link->href, "\n";
    }

    sleep 1;
} while ( $reader->feed( $feed ) );
