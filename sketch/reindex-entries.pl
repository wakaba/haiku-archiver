use strict;
use warnings;
use Path::Tiny;
use JSON::PS;
use Web::DateTime::Parser;

my $RootPath = path (__FILE__)->parent->parent;

my $n = 0;
my @dir_path = $RootPath->child ('data/entries')->children;
my $all = @dir_path;
my $dtp = Web::DateTime::Parser->new;
for (@dir_path) {
  printf STDERR "\rUser %d/%d", ++$n, $all;
  next unless $_->is_dir;
  for (($_->children)) {
    if ($_ =~ m{\.[nh]\.json$}) {
      my $json = json_bytes2perl $_->slurp;
      printf "%010d %s/%s/%s %s %s/%s\n",
          $json->{created_on} // $dtp->parse_global_date_and_time_string ($json->{created_at})->to_unix_number,
          $json->{tld},
          $json->{author}->{url_name} // $json->{user}->{screen_name},
          $json->{eid} // $json->{id},
          $json->{target}->{url_name} // '@',
          $json->{reply_to_author}->{url_name} // $json->{in_reply_to_user_id} // '',
          $json->{reply_to_eid} // $json->{in_reply_to_status_id} // '';
    }
  }
}
