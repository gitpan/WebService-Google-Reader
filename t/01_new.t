use strict;
use Test::More tests=>3;
use WebService::Google::Reader;

{
    my $reader = WebService::Google::Reader->new;
    isa_ok( $reader, 'WebService::Google::Reader', 'Reader->new()' );
}

{
    my @methods = qw(
        error password scheme ua username
        edit feed list search
        subscribe unsubscribe subscriptions subs feeds tags labels opml        
        _login _request _token _public _cookie _encode_type
    );
    can_ok( 'WebService::Google::Reader', @methods );
}

{
    my @methods = qw(
        continuation ids request
    );
    can_ok( 'WebService::Google::Reader::Feed', @methods );
}
