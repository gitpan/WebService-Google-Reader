#!/usr/bin/env perl
use strict;
use warnings;
use WebService::Google::Reader;

my $reader = WebService::Google::Reader->new(
    username => $ENV{GOOGLE_USERNAME},
    password => $ENV{GOOGLE_PASSWORD},
);

# Unsubscribe from all feeds.
$reader->unsubscribe( map { $_->id } $reader->subs ) or die $reader->error;

# Delete all tags.
$reader->edit( label => [ map { $_->id } $reader->tags ], delete => 1 )
    or die $reader->error;
