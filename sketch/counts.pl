use strict;
use warnings;
use Path::Tiny;

my $RootPath = path (__FILE__)->parent->parent;

my $Data = {};

my $entries_path = $RootPath->child ('data/indexes/entries.txt');
my $file = $entries_path->openr;
my $prev_mkey = '';
my $users = {};
while (<$file>) {
  if (m{^([0-9]+) (jp|com)/([^/]+)/[0-9]+ (\S+) [^/]*/[^/]*$}) {
    my $time = $1;
    my $tld = $2;
    my $user = $3;
    my $target = $4;
    my (undef, undef, undef, undef, $month, $year) = gmtime $time;
    $month++;
    $year += 1900;
    my $mkey = sprintf '%04d-%02d', $year, $month;
    if ($mkey ne $prev_mkey) {
      $Data->{$prev_mkey}->{count_user} = keys %$users;

      $users = {};
      print STDERR "\r$mkey";
      $prev_mkey = $mkey;
    }

    my $tt = 'id';
    if ($target =~ /\@(.+)$/) {
      $tt = $1;
    }

    $users->{$user} = 1;

    $Data->{$mkey}->{count_all}++;
    $Data->{$mkey}->{'count_'.$tld}++;
    $Data->{$mkey}->{'count_'.$tt}++;
    $Data->{all}->{count_all}++;
  }
}

my @Column = qw(count_all count_jp count_com count_h count_asin count_http count_id count_facebook count_user);
print "month";
print "\t$_" for @Column;
print "\n";
for my $key (sort { $a cmp $b } keys %$Data) {
  print $key;
  for (@Column) {
    print "\t", $Data->{$key}->{$_} // 0;
  }
  print "\n";
}
