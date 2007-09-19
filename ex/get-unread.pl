#!/usr/bin/env perl
use strict;
use warnings;
use WebService::Google::Reader;

my $user = shift or die 'missing username';
my $pass = shift or die 'missing password';

my $reader = WebService::Google::Reader->new(
    username => $user,
    password => $pass,
);

my $feed = $reader->feed(
    state => 'reading-list', count => 100, continue => 1,
) or die $reader->error;

while ( my $entry = $feed->entry ) {
    print $entry->title, "\n";
    print $entry->link->href, "\n";
}
