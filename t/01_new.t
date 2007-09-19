use strict;
use Test::More tests=>3;
use WebService::Google::Reader;

{
    my $reader = WebService::Google::Reader->new;
    isa_ok( $reader, 'WebService::Google::Reader', 'Reader->new()' );
}

{
    my @methods = qw(
        login feed _request
        continue cookie error password scheme response ua username
    );
    can_ok( 'WebService::Google::Reader', @methods );
}

{
    my @methods = qw(
        entry continuation previous continue reader request
    );
    can_ok( 'WebService::Google::Reader::Feed', @methods );
}
