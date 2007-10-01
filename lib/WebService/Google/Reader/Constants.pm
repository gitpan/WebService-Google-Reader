package WebService::Google::Reader::Constants;

use strict;
use base qw( Exporter );

our @EXPORT = do {
    no strict 'refs';
    ( qw( DEBUG HAS_ZLIB ), grep /_URL$/, keys %{ __PACKAGE__.'::' } );
};

use constant DEBUG => $ENV{ WEBSERVICE_GOOGLE_READER_DEBUG } || 0;

my $has_zlib;
BEGIN {
    $has_zlib = eval { require Compress::Zlib; 1 } ? 1 : 0;
}
use constant HAS_ZLIB => $has_zlib;

use constant LOGIN_URL => 'https://www.google.com/accounts/ClientLogin';
use constant READER_URL => 'http://www.google.com/reader';
use constant TOKEN_URL => READER_URL.'/api/0/token';

use constant ATOM_PUBLIC_URL => READER_URL.'/public/atom/';
use constant ATOM_URL => READER_URL.'/atom/';
use constant API_URL => READER_URL.'/api/0';
use constant EXPORT_SUBS_URL => READER_URL.'/subscribtions/export';

use constant EDIT_ITEM_TAG_URL => API_URL.'/edit-tag';
use constant EDIT_SUB_URL => API_URL.'/subscription/edit';
use constant EDIT_TAG_DISABLE_URL => API_URL.'/disable-tag';
use constant EDIT_TAG_SHARE_URL => API_URL.'/tag/edit';
use constant LIST_COUNTS_URL => API_URL.'/unread-count?all=true';
use constant LIST_PREFS_URL => API_URL.'/preference/list';
use constant LIST_SUBS_URL => API_URL.'/subscription/list';
use constant LIST_TAGS_URL => API_URL.'/tag/list';
use constant SEARCH_IDS_URL => API_URL.'/search/items/ids';
use constant SEARCH_CONTENTS_URL  => API_URL.'/stream/items/contents';

1;

__END__

=head1 NAME

WebService::Google::Reader::Constants

=cut
