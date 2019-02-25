use strict;
use warnings;
use Carp;
use Path::Tiny;
use AbortController;
use AnyEvent;
use Promise;
use Promised::Flow;
use Promised::File;
use Web::Encoding;
use Web::URL;
use JSON::PS;
use Web::Transport::BasicClient;
use Web::DateTime;
use Web::DateTime::Parser;

my $DataPath = path (__FILE__)->parent->parent->child ('data');
my $DEBUG = $ENV{DEBUG};

my $Counts = {entries => 0, timestamp => 0};
sub reset_count () {
  print STDERR sprintf "\rEntries: %d %s",
      $Counts->{entries}, scalar gmtime $Counts->{timestamp};
  $Counts = {entries => 0, timestamp => 0};
} # reset_count
my $CountInterval = 60;
my $timer = AE::timer $CountInterval, $CountInterval, sub {
  reset_count;
};

sub debug_req ($) {
  my $req = shift;
  if ($DEBUG) {
    print STDERR "\r", $req->{url}->stringify if defined $req->{url};
    print STDERR "\r", join ("/", @{$req->{path}}) if defined $req->{path};
    for (keys %{$req->{params} or {}}){
      print STDERR encode_web_utf8 (' ' . $_ . "=" . $req->{params}->{$_});
    }
  }
  return %$req;
} # debug_req

{
  my $TryCount = 0;

  sub with_retry ($$) {
    my $code = shift;
    my $signal = shift;
    my $return;
    my $n = 0;
    return ((promised_wait_until {
      if ($signal->aborted) {
        $return = undef;
        return 'done';
      }
      $TryCount++;
      return Promise->resolve->then ($code)->then (sub {
        $return = $_[0];
        return 'done';
      }, sub {
        my $e = $_[0];
        die $e if $n++ > 5;
        warn "Failed ($e); retrying ($n)...\n";
        return not 'done';
      });
    } interval => 60)->then (sub {
      return $return;
    }));
  } # with_retry

  my $PrevTryCount = 0;
  sub sleeper ($) {
    my $signal = shift;
    return sub {
      return if $signal->aborted;
      return if $PrevTryCount == $TryCount;
      $PrevTryCount = $TryCount;
      if (($TryCount % 1000) == 0) {
        warn "Sleep (75)\n" if $DEBUG;
        return promised_sleep 75;
      } elsif (($TryCount % 100) == 0) {
        warn "Sleep (25)\n" if $DEBUG;
        return promised_sleep 25;
      } else {
        return promised_sleep 5;
      }
    };
  } # sleeper
}

sub validate_name ($) {
  my $name = shift;
  die "Unexpected name |$name|", Carp::longmess
      unless $name =~ m{\A[0-9A-Za-z\@_-]+\z};
} # validate_name

{
  {
    my $path = $DataPath->child ('indexes', 'users.txt.orig');
    $path->parent->mkpath;
    my $file = $path->opena;
    sub index_user (%) {
      my %args = @_;
      validate_name $args{url_name};
      printf $file "%s\n",
          $args{url_name};
    } # index_user

    sub close_user_index () { close $file }
  }

  {
    my $path = $DataPath->child ('indexes', 'keywords.txt.orig');
    $path->parent->mkpath;
    my $file = $path->opena_utf8;
    sub index_target_keyword (%) {
      my %args = @_;
      my $word = $args{word};
      ## ^<https://chars.suikawiki.org/set?expr=-+%24unicode%3ANoncharacter_Code_Point+-+%24unicode%3AZ+-+%24unicode%3AWhite_Space+-+%24unicode%3Asurrogate+-+%24unicode%3ADefault_Ignorable_Code_Point+-+%24unicode%3AControl+-+%5B%5Cu005C%5D>
      $word =~ s/([^!-\x5B\x5D-~\xA1-\xAC\xAE-\x{034E}\x{0350}-\x{061B}\x{061D}-\x{115E}\x{1161}-\x{167F}\x{1681}-\x{17B3}\x{17B6}-\x{180A}\x{180F}-\x{1FFF}\x{2010}-\x{2027}\x{2030}-\x{205E}\x{2070}-\x{2FFF}\x{3001}-\x{3163}\x{3165}-\x{D7FF}\x{E000}-\x{FDCF}\x{FDF0}-\x{FDFF}\x{FE10}-\x{FEFE}\x{FF00}-\x{FF9F}\x{FFA1}-\x{FFEF}\x{FFF9}-\x{FFFD}\x{10000}-\x{1BC9F}\x{1BCA4}-\x{1D172}\x{1D17B}-\x{1FFFD}\x{20000}-\x{2FFFD}\x{30000}-\x{3FFFD}\x{40000}-\x{4FFFD}\x{50000}-\x{5FFFD}\x{60000}-\x{6FFFD}\x{70000}-\x{7FFFD}\x{80000}-\x{8FFFD}\x{90000}-\x{9FFFD}\x{A0000}-\x{AFFFD}\x{B0000}-\x{BFFFD}\x{C0000}-\x{CFFFD}\x{D0000}-\x{DFFFD}\x{E1000}-\x{EFFFD}\x{F0000}-\x{FFFFD}\x{100000}-\x{10FFFD}])/sprintf "\\x{%04X}", ord $1/ge;
      printf $file "%s %s\n",
          $args{url_name},
          $word;
    } # index_target_keyword

    sub close_target_keyword_index () { close $file }
  }

  {
    my $path = $DataPath->child ('indexes', 'https.txt.orig');
    $path->parent->mkpath;
    my $file = $path->opena_utf8;
    sub index_target_http (%) {
      my %args = @_;
      my $word = $args{word};
      ## ^<https://chars.suikawiki.org/set?expr=-+%24unicode%3ANoncharacter_Code_Point+-+%24unicode%3AZ+-+%24unicode%3AWhite_Space+-+%24unicode%3Asurrogate+-+%24unicode%3ADefault_Ignorable_Code_Point+-+%24unicode%3AControl+-+%5B%5Cu005C%5D>
      $word =~ s/([^!-\x5B\x5D-~\xA1-\xAC\xAE-\x{034E}\x{0350}-\x{061B}\x{061D}-\x{115E}\x{1161}-\x{167F}\x{1681}-\x{17B3}\x{17B6}-\x{180A}\x{180F}-\x{1FFF}\x{2010}-\x{2027}\x{2030}-\x{205E}\x{2070}-\x{2FFF}\x{3001}-\x{3163}\x{3165}-\x{D7FF}\x{E000}-\x{FDCF}\x{FDF0}-\x{FDFF}\x{FE10}-\x{FEFE}\x{FF00}-\x{FF9F}\x{FFA1}-\x{FFEF}\x{FFF9}-\x{FFFD}\x{10000}-\x{1BC9F}\x{1BCA4}-\x{1D172}\x{1D17B}-\x{1FFFD}\x{20000}-\x{2FFFD}\x{30000}-\x{3FFFD}\x{40000}-\x{4FFFD}\x{50000}-\x{5FFFD}\x{60000}-\x{6FFFD}\x{70000}-\x{7FFFD}\x{80000}-\x{8FFFD}\x{90000}-\x{9FFFD}\x{A0000}-\x{AFFFD}\x{B0000}-\x{BFFFD}\x{C0000}-\x{CFFFD}\x{D0000}-\x{DFFFD}\x{E1000}-\x{EFFFD}\x{F0000}-\x{FFFFD}\x{100000}-\x{10FFFD}])/sprintf "\\x{%04X}", ord $1/ge;
      printf $file "%s %s\n",
          $args{url_name},
          $word;
    } # index_target_http

    sub close_target_http_index () { close $file }
  }

  sub index_target (%) {
    my %args = @_;
    if (defined $args{url_name}) {
      validate_name $args{url_name};
      if ($args{url_name} =~ m{\@(?:h)$}) {
        if ($args{url_name} eq '9234293841040390341@h') {
          ## <http://h.hatena.ne.jp/api/statuses/keywords/kk_solanet.json>
          ## <http://h.hatena.ne.jp/api/statuses/keyword_timeline/id:kk_solanet@ustream%20.json>
          $args{word} //= 'id:kk_solanet@ustream';
          $args{title} //= 'id:kk_solanet@ustream';
        }
        
        my $word = $args{word} // $args{title};
        index_target_keyword word => $word, url_name => $args{url_name};
      } elsif ($args{url_name} =~ m{^(.+)\@(?:asin)$}) {
        #
      } elsif ($args{url_name} =~ m{\@(?:http)$}) {
        if (defined $args{word}) {
          index_target_http word => $args{word}, url_name => $args{url_name};
        } else {
          return;
        }
      } else {
        index_user url_name => $args{url_name};
        return;
      }
    }
  } # index_target

  {
    my $path = $DataPath->child ('indexes', 'entries.txt.orig');
    $path->parent->mkpath;
    my $file = $path->opena;
    sub index_entry (%) {
      my %args = @_;
      $Counts->{entries}++;
      printf $file "%010d %s/%s/%s %s %s/%s\n",
          $args{timestamp},
          $args{tld}, $args{user}, $args{eid},
          $args{target} // '@',
          $args{parent_user} // '', $args{parent_eid} // '';
    } # index_entry

    sub close_entry_index () { close $file }
  }
  
  sub generate_sorted_indexes_u () {
    print STDERR "\rSorting (u)...";
    {
      my $path1 = $DataPath->child ('indexes', 'users.txt.orig');
      my $path2 = $DataPath->child ('indexes', 'users.txt');
      `sort -u \Q$path1\E > \Q$path2\E`;
    }
  } # generate_sorted_indexes_u

  sub generate_sorted_indexes_0 () {
    print STDERR "\rSorting (0)...";
    {
      my $path1 = $DataPath->child ('indexes', 'entries.txt.orig');
      my $path2 = $DataPath->child ('indexes', 'entries.txt');
      `sort -u \Q$path1\E > \Q$path2\E`;
    }
    #{
    #  my $path1 = $DataPath->child ('indexes', 'keywords.txt.orig');
    #  my $path2 = $DataPath->child ('indexes', 'keywords.txt');
    #  `sort -u \Q$path1\E > \Q$path2\E`;
    #}
    {
      my $path1 = $DataPath->child ('indexes', 'https.txt.orig');
      my $path2 = $DataPath->child ('indexes', 'https.txt');
      `sort -u \Q$path1\E > \Q$path2\E`;
    }
    #generate_sorted_indexes_u;
  } # generate_sorted_indexes_0

  sub generate_sorted_indexes () {
    print STDERR "\rSorting...";
    {
      close_entry_index;
      my $path1 = $DataPath->child ('indexes', 'entries.txt.orig');
      my $path2 = $DataPath->child ('indexes', 'entries.txt');
      `sort -u \Q$path1\E > \Q$path2\E`;
    }
    {
      close_target_keyword_index;
      my $path1 = $DataPath->child ('indexes', 'keywords.txt.orig');
      my $path2 = $DataPath->child ('indexes', 'keywords.txt');
      `sort -u \Q$path1\E > \Q$path2\E`;
    }
    {
      close_target_http_index;
      my $path1 = $DataPath->child ('indexes', 'https.txt.orig');
      my $path2 = $DataPath->child ('indexes', 'https.txt');
      `sort -u \Q$path1\E > \Q$path2\E`;
    }
    {
      close_user_index;
      generate_sorted_indexes_u;
    }
  } # generate_sorted_indexes
}

{
  my $States = {};
  my $StateNames = [qw(keyword asin http public)];
  
  sub load_states () {
    return promised_for {
      my $name = shift;
      my $path = $DataPath->child ('states', $name . '.json');
      my $file = Promised::File->new_from_path ($path);
      return $file->is_file->then (sub {
        return {} unless $_[0];
        return $file->read_byte_string->then
            (sub { return json_bytes2perl $_[0] });
      })->then (sub {
        $States->{$name} = $_[0];
      });
    } $StateNames;
  } # load_states

  sub save_states () {
    return promised_for {
      my $name = shift;
      my $path = $DataPath->child ('states', $name . '.json');
      return Promised::File->new_from_path ($path)->write_byte_string (perl2json_bytes $States->{$name});
    } $StateNames;
  } # save_states

  sub load_state_all ($) {
    my $file = shift;
    return $file->is_file->then (sub {
      return {} unless $_[0];
      return $file->read_byte_string->then (sub {
        return json_bytes2perl $_[0];
      });
    })->then (sub {
      my $state_all = $_[0];
      return $state_all;
    });
  } # load_state_all

  sub save_sh ($) {
    my $sh = $_[0];
    return Promise->all ([
      (defined $sh->{file} ? $sh->{file}->write_byte_string (perl2json_bytes $sh->{all}) : undef),
      (defined $sh->{graph_file} ? $sh->{graph_file}->write_byte_string (perl2json_bytes $sh->{graphs}) : undef),
    ]);
  } # save_sh

  sub state_h ($$;%) {
    my ($type, $tld, %args) = @_;
    my $all;
    if ($type eq 'user') {
      validate_name $args{name};
      my $path = $DataPath->child ('states', 'users', $args{name} . '.json');
      my $file = Promised::File->new_from_path ($path);
      return load_state_all ($file)->then (sub {
        my $all = $_[0];
        return {state => $all->{'h_'.$tld} ||= {}, all => $all, file => $file};
      });
    } elsif ($type eq 'keyword') {
      if ($args{word} =~ /^asin:/i) {
        $all = $States->{asin}->{$args{word}} ||= {};
      } elsif ($args{word} =~ /^http:/i) {
        $all = $States->{http}->{$args{word}} ||= {};
      } else {
        $all = $States->{keyword}->{$args{word}} ||= {};
      }
    } elsif ($type eq 'public') {
      $all = $States->{public} ||= {};
    } else {
      die "Bad type |$type|";
    }
    return {state => $all->{'h_' . $tld} ||= {}};
  } # state_h

  sub state_n ($;%) {
    my ($type, %args) = @_;
    if ($type eq 'user' or $type eq 'user2') {
      validate_name $args{name};
      my $path = $DataPath->child ('states', 'users', $args{name} . '.json');
      my $file = Promised::File->new_from_path ($path);
      return load_state_all ($file)->then (sub {
        my $all = $_[0];
        return {state => $all->{$type eq 'user2' ? 'n2' : 'n'} ||= {},
                all => $all, file => $file};
      });
    } elsif ($type eq 'public') {
      return {state => $States->{public}->{n_jp} ||= {}};
    } else {
      die "Bad type |$type|";
    }
  } # state_n

  sub state_graph ($;%) {
    my ($type, %args) = @_;
    if ($type eq 'user') {
      validate_name $args{name};
      my $path = $DataPath->child ('states', 'users', $args{name} . '.json');
      my $file = Promised::File->new_from_path ($path);
      my $graph_path = $DataPath->child ('graphs', 'users', $args{name} . '.json');
      my $graph_file = Promised::File->new_from_path ($graph_path);
      return load_state_all ($file)->then (sub {
        my $all = $_[0];
        return $graph_file->is_file->then (sub {
          return {} unless $_[0];
          return $graph_file->read_byte_string->then (sub {
            return json_bytes2perl $_[0];
          });
        })->then (sub {
          my $graphs = $_[0];
          return {state => $all->{graph} ||= {},
                  all => $all, file => $file,
                  graphs => $graphs, graph_file => $graph_file};
        });
      });
    } else {
      die "Bad type |$type|";
    }
  } # state_graph
}

sub write_keyword ($) {
  my $data = $_[0];
  validate_name $data->{url_name};
  my $type = 'id';
  if ($data->{url_name} =~ /\@(\w+)$/) {
    $type = $1;
  }
  my $path = $DataPath->child ('keywords', $type, $data->{url_name} . '.json');
  my $file = Promised::File->new_from_path ($path);
  return $file->is_file->then (sub {
    return $file->write_byte_string (perl2json_bytes $data);
  });
} # write_keyword

sub write_entry ($$$$) {
  my ($user, $eid, $type, $data) = @_;
  my $path = $DataPath->child ('entries')
      ->child ($user)
      ->child ($eid . '.' . $type . '.json');
  my $file = Promised::File->new_from_path ($path);
  return $file->is_file->then (sub {
    return if $_[0]; # skip
    return $file->write_byte_string (perl2json_bytes $data);
  });
} # write_entry

sub save_h_entries ($) {
  my ($items) = @_;
  return promised_for {
    my $item = shift;

    validate_name $item->{user}->{screen_name};
    validate_name $item->{id};
    validate_name $item->{tld};

    my $ts = Web::DateTime::Parser->parse_global_date_and_time_string
        ($item->{created_at});

    index_user
        url_name => $item->{user}->{screen_name};
    index_target
        url_name => $item->{target}->{url_name},
        word => $item->{target}->{word},
        title => $item->{target}->{title}
        if defined $item->{target}->{word};
    index_target
        word => $item->{source} if defined $item->{source};

    if (length $item->{in_reply_to_user_id}) {
      index_user
          url_name => $item->{in_reply_to_user_id};
    }
    for (@{$item->{replies}}) {
      index_user
          url_name => $_->{user}->{screen_name};
    }

    index_entry
        tld => $item->{tld},
        user => $item->{user}->{screen_name},
        eid => $item->{id},
        target => $item->{target}->{url_name},
        timestamp => $ts->to_unix_number,
        parent_user => $item->{in_reply_to_user_id},
        parent_eid => $item->{in_reply_to_status_id};

    return write_entry $item->{user}->{screen_name}, $item->{id}, 'h', $item;
  } $items;
} # save_h_entries

sub save_n_entries ($) {
  my ($items) = @_;
  return promised_for {
    my $item = shift;
    return unless $item->{data_category} == 62;
    
    validate_name $item->{author}->{url_name};
    validate_name $item->{eid};
    validate_name $item->{tld};

    index_user
        url_name => $item->{author}->{url_name};
    index_target
        url_name => $item->{target}->{url_name},
        title => $item->{target}->{display_name}
        if defined $item->{target}->{display_name};
    index_target
        url_name => $item->{source_target}->{url_name},
        title => $item->{source_target}->{display_name}
        if defined $item->{source_target}->{display_name};

    if (defined $item->{reply_to_author}) {
      index_user
          url_name => $item->{reply_to_author}->{url_name};
    }

    index_entry
        tld => $item->{tld},
        user => $item->{author}->{url_name},
        eid => $item->{eid},
        target => $item->{target}->{url_name},
        timestamp => $item->{created_on},
        parent_user => $item->{reply_to_author}->{url_name},
        parent_eid => $item->{reply_to_eid};
    
    return write_entry $item->{author}->{url_name}, $item->{eid}, 'n', $item;
  } $items;
} # save_n_entries

{
  my $Clients = {};
  sub client ($) {
    my $tld = shift;
    return $Clients->{$tld} ||= Web::Transport::BasicClient->new_from_url
        (Web::URL->parse_string ($tld eq 'com' ? 'http://h.hatena.com' : "http://h.hatena.ne.jp"));
  } # client
  sub new_client ($) {
    my $tld = shift;
    $Clients->{$tld}->close if defined $Clients->{$tld};
    return $Clients->{$tld} = Web::Transport::BasicClient->new_from_url
        (Web::URL->parse_string ($tld eq 'com' ? 'http://h.hatena.com' : "http://h.hatena.ne.jp"));
  } # new_client

  sub close_clients () {
    return Promise->all ([
      map { (delete $Clients->{$_})->close } keys %$Clients
    ]);
  } # close_clients
}

sub get_h ($$%) {
  my ($type, $tld, %args) = @_;
  return Promise->resolve->then (sub {
    return state_h $type, $tld, name => $args{name}, word => $args{word};
  })->then (sub {
    my $sh = $_[0];
    my $state = $sh->{state};
    my $ref;
    my $since;
    return if $sh->{all}->{'404'};
    if ($state->{ref_no_more_newer}) {
      return;
    } elsif (defined $state->{ref_latest_timestamp}) {
      $ref = '+' . $state->{ref_latest_timestamp} . ',1';
    } elsif ($tld eq 'com' and $state->{no_more_older}) {
      if ($state->{can_have_more}) {
        $ref = '+0,0';
      } else {
        return;
      }
    } else {
      if ($state->{can_have_more}) {
        $ref = '+0,0';
      } elsif ($state->{no_more_older} and defined $state->{latest_timestamp}) {
        $ref = '+' . $state->{latest_timestamp} . ',1';
      } else {
        $ref = '+0,0';
      }
    }
    my $client = client $tld;
    return ((promised_until {
      return with_retry (sub {
        return $client->request (debug_req {
          path => [
            'api', 'statuses',
            ($type eq 'user' ? ($type . '_timeline', $args{name} . '.json')
                             : ($type . '_timeline.json')),
          ],
          params => {
            body_formats => 'haiku',
            count => 200,
            ($type eq 'keyword' ? (word => $args{word}) : ()),
            reftime => $ref,
          },
        })->then (sub {
          my $res = $_[0];
          $sh->{all}->{'404'} = 1 if $res->status == 404;
          return [] if $res->status == 404;
          return [] if $res->status == 401 and defined $args{name} and $args{name} =~ m{^admin};
          if ($res->status != 200) {
            $client = new_client $tld;
          }
          die $res unless $res->status == 200;
          return json_bytes2perl $res->body_bytes;
        });
      }, $args{signal})->then (sub {
        my $json = $_[0];
        return 'done' if $args{signal}->aborted and not defined $json;
        if (ref $json eq 'ARRAY') {
          unless (@$json) {
            $state->{ref_no_more_newer} = 1 if $tld eq 'com';
            $state->{ref_no_more_newer} = 1 if $type eq 'user' and $args{name} =~ /\@(?:facebook|twitter|mixi|DSi)$/;
            delete $state->{can_have_more};
            return 'done';
          }
          
          my $ts0 = Web::DateTime::Parser->parse_global_date_and_time_string
              ($json->[0]->{created_at});
          $state->{ref_latest_timestamp} = $ts0->to_unix_number
              if not defined $state->{ref_latest_timestamp} or
                 $state->{ref_latest_timestamp} < $ts0->to_unix_number;
          $Counts->{timestamp} = $ts0->to_unix_number;
          my $new_ref = '+' . $ts0->to_unix_number . ',1';
          return 'done' if $new_ref eq $ref; # no newer
          $ref = $new_ref;
          
          $_->{tld} = $tld for @$json;
          return Promise->all ([
            save_h_entries ($json),
          ])->then (sub {
            print STDERR "*";
            return 'done' if $args{signal}->aborted;
            return not 'done';
          });
        } else {
          die "Server returns an unexpected response";
        }
      });
    })->then (sub {
      return 'done' if $args{signal}->aborted;
      return save_sh $sh;
    }));
  });
} # get_h

sub get_n ($%) {
  my ($type, %args) = @_;
  return Promise->resolve->then (sub {
    return state_n $type, name => $args{name};
  })->then (sub {
    my $sh = $_[0];
    my $state = $sh->{state};
    return if $sh->{all}->{'404'};
    return if $state->{no_more_newer};
    return if $type eq 'user2' and not $sh->{all}->{h_com}->{can_have_more};
    return if $args{skip_recently_checked} and
        defined $state->{last_checked} and
        $state->{last_checked} > time - 10*24*60*60;
    return if $args{skip_not_active} and
        defined $state->{latest_timestamp} and
        $state->{latest_timestamp} + 100*24*60*60 < time;
    my $client = client 'jp';
    my $req = $type eq 'user' ? {
      path => [$args{name}, 'index.json'],
      params => {
        per_page => 200,
        order => 'asc',
      },
    } : $type eq 'user2' ? {
      path => [$args{name}, 'index.json'],
      params => {
        location => q<http://h2.hatena.ne.jp/>,
        dccol => 'ugouser',
        per_page => 200,
        order => 'asc',
        reftime => '+1291161600,0', # 2010-12-01
      },
    } : $type eq 'public' ? {
      path => ['index.json'],
      params => {
        per_page => 200,
        order => 'asc',
      },
    } : die;
    if (defined $state->{newer_url}) {
      $req = {url => Web::URL->parse_string ($state->{newer_url})};
    }
    my $n = 0;
    my $time = time;
    return ((promised_until {
      $time = time;
      return with_retry (sub {
        debug_req $req;
        return $client->request (%$req)->then (sub {
          my $res = $_[0];
          $sh->{all}->{'404'} = 1 if $res->status == 404;
          return {items => []} if $res->status == 404;
          return {items => []} if $res->status == 401 and $args{name} =~ m{^admin};
          if ($res->status != 200) {
            $client = new_client 'jp';
          }
          die $res unless $res->status == 200;
          return json_bytes2perl $res->body_bytes;
        });
      }, $args{signal})->then (sub {
        my $json = $_[0];
        return 'done' if $args{signal}->aborted and not defined $json;
        if (ref $json eq 'HASH') {
          $state->{newer_url} = $json->{newer_url};
          unless (@{$json->{items}}) {
            $state->{no_more_newer} = 1 if $type eq 'user2';
            $state->{no_more_newer} = 1 if $type eq 'user' and $args{name} =~ /\@(?:facebook|twitter|mixi|DSi)$/;
            return 'done';
          }

          return Promise->all ([
            save_n_entries ($json->{items}),
          ])->then (sub {
            if ($DEBUG) {
              my $ts = Web::DateTime->new_from_unix_time
                  ($json->{items}->[-1]->{created_on});
              print STDERR "\x0D" . $ts->to_global_date_and_time_string;
            }
            $Counts->{timestamp} = $json->{items}->[-1]->{created_on};
            if (not defined $state->{latest_timestamp} or
                $state->{latest_timestamp} < $json->{items}->[0]->{created_on}) {
              $state->{latest_timestamp} = $json->{items}->[0]->{created_on};
            }
            if ($type eq 'user2' and
                $sh->{all}->{h_com}->{oldest_timestamp} < $Counts->{timestamp}) {
              $state->{no_more_newer} = 1;
              return 'done';
            }
            return 'done' if $args{signal}->aborted;
            $req = {
              url => Web::URL->parse_string ($json->{newer_url}),
            };
            $n++;
            return save ()->then (sub {
              return not 'done';
            });
          });
        } else {
          die "Server returns an unexpected response";
        }
      });
    })->then (sub {
      $state->{last_checked} = $time unless $args{signal}->aborted;
      return save_sh $sh;
    }));
  });
} # get_n

sub get_users ($$%) {
  my ($type, %args) = @_;
  return Promise->resolve->then (sub {
    return state_graph 'user', name => $args{name};
  })->then (sub {
    my $sh = $_[0];
    my $state = $sh->{state};
    my $ts = $state->{$type . '_user_updated'};
    return if defined $ts;
    return if $sh->{all}->{'404'};
    my $client = client 'jp';
    my $page = 1;
    return ((promised_until {
      return with_retry (sub {
        return $client->request (debug_req {
        path => [
          'api', 'statuses',
          ({
            favorite => 'friends',
            fan => 'followers',
          }->{$type} // die "Bad type |$type|"),
          $args{name} . '.json'
        ],
        params => {
          page => $page,
        },
      })->then (sub {
        my $res = $_[0];
        $sh->{all}->{'404'} = 1 if $res->status == 404;
        return [] if $res->status == 404;
        return [] if $res->status == 401 and $args{name} =~ m{^admin};
        if ($res->status != 200) {
          $client = new_client 'jp';
        }
        die $res unless $res->status == 200;
        return json_bytes2perl $res->body_bytes;
      });
    }, $args{signal})->then (sub {
      my $json = $_[0];
      return 'done' if $args{signal}->aborted and not defined $json;
      if (ref $json eq 'ARRAY') {
        return 'done' unless @$json;

          for my $item (@$json) {
            index_user
                url_name => $item->{screen_name};
            $sh->{graphs}->{$type . '_user'}->{$item->{screen_name}} = 1;
          }

        return 'done' if $page++ > 100;
        print STDERR "*";
        return 'done' if $args{signal}->aborted;
        return not 'done';
      } else {
        die "Server returns an unexpected response";
      }
    });
    })->then (sub {
      return if $args{signal}->aborted;
      $state->{$type . '_user_updated'} = time;
      return save_sh $sh;
    }));
  });
} # get_users

sub get_favorite_keywords (%) {
  my (%args) = @_;
  return Promise->resolve->then (sub {
    return state_graph 'user', name => $args{name};
  })->then (sub {
    my $sh = $_[0];
    my $state = $sh->{state};
    my $ts = $state->{favorite_keyword_updated};
    return if defined $ts;
    return if $sh->{all}->{'404'};
    my $client = client 'jp';
    my $page = 1;
    my $prev_count = 0;
    return ((promised_until {
      return with_retry (sub {
        return $client->request (debug_req {
          path => [
            'api', 'statuses',
            'keywords',
            $args{name} . '.json'
          ],
          params => {
            page => $page,
          },
        })->then (sub {
          my $res = $_[0];
          $sh->{all}->{'404'} = 1 if $res->status == 404;
          return [] if $res->status == 404;
          return [] if $res->status == 401 and $args{name} =~ m{^admin};
          if ($res->status != 200) {
            $client = new_client 'jp';
          }
          die $res unless $res->status == 200;
          return json_bytes2perl $res->body_bytes;
        });
      }, $args{signal})->then (sub {
        my $json = $_[0];
        return 'done' if $args{signal}->aborted and not defined $json;
        if (ref $json eq 'ARRAY') {
          return 'done' unless @$json;

          for my $item (@$json) {
            if (($item->{url_name} // '') eq '9234293841040390341@h') {
              ## <http://h.hatena.ne.jp/api/statuses/keywords/kk_solanet.json>
              ## <http://h.hatena.ne.jp/api/statuses/keyword_timeline/id:kk_solanet@ustream%20.json>
              $item->{word} //= 'id:kk_solanet@ustream';
            }
            $sh->{graphs}->{favorite_keyword}->{$item->{word}} = 1
                if defined $item->{word};
          }
          return ((promised_for {
            unless (defined $_[0]->{url_name}) {
              $state->{has_broken_keyword}++;
              ## <http://h.hatena.ne.jp/api/statuses/keywords/nano_001.json>
              ## (has been broken since
              ## <https://web.archive.org/web/20091107063850/http://h.hatena.ne.jp:80/nano_001/>)
              return;
            }
            return write_keyword $_[0]
          } $json)->then (sub {
            return 'done' if @$json != 100 and $prev_count == @$json;
            $prev_count = @$json;

            return 'done' if $page++ > 100;
            print STDERR "*";
            return 'done' if $args{signal}->aborted;
            return not 'done';
          }));
        } else {
          die "Server returns an unexpected response";
        }
      });
    })->then (sub {
      return if $args{signal}->aborted;
      $state->{favorite_keyword_updated} = time;
      return save_sh $sh;
    }));
  });
} # get_favorite_keywords

sub get_entry ($$$) {
  my ($tld, $eid, $signal) = @_;
  my $client = client 'jp';
  return ((promised_until {
    return with_retry (sub {
      return $client->request (debug_req {
        path => ['api', 'statuses', 'show', $eid . '.json'],
        params => {
          body_formats => 'haiku',
        },
      })->then (sub {
        my $res = $_[0];
        return undef if $res->status == 404;
        if ($res->status != 200) {
          $client = new_client 'jp';
        }
        die $res unless $res->status == 200;
        return json_bytes2perl $res->body_bytes;
      });
    }, $signal)->then (sub {
      my $json = $_[0];
      return 'done' if $signal->aborted and not defined $json;
      return 'done' if not defined $json; # 404
      if (ref $json eq 'HASH') {
        $json->{tld} = $tld;
        return Promise->all ([
          save_h_entries ([$json]),
        ])->then (sub {
          return 'done';
        });
      } else {
        die "Server returns an unexpected response";
      }
    });
  }));
} # get_entry

sub run_resolve_https ($) {
  my $signal = shift;
  return if $signal->aborted;

  my $known = {};
  {
    print STDERR "\rReading \@http list...";
    my $known_txt_path = $DataPath->child ('indexes', 'https.txt');
    if (-f $known_txt_path) {
      my $file = $known_txt_path->openr;
      while (<$file>) {
        if (/^([0-9]+\@http) ./) {
          $known->{$1} = 1;
        }
      }
    }
  }

  return Promise->resolve->then (sub {
    print STDERR "\rReading entry list for \@http...";
    my $entries_txt_path = $DataPath->child ('indexes', 'entries.txt');
    my $file = $entries_txt_path->openr;
    return promised_until {
      while (1) {
        my $line = <$file>;
        return 'done' if not defined $line;
        return 'done' if $signal->aborted;
        if ($line =~ m{^([0-9]+) (jp|com)/[^/]+/([0-9]+) ([0-9]+\@http) }) {
          $Counts->{timestamp} = $1;
          return not 'done' if $known->{$4};
          my $url_name = $4;

          printf STDERR "\r\@http: %s",
              scalar gmtime $1;
          return get_entry ($2, $3, $signal)->then (sub {
            $known->{$url_name} = 1;
            return not 'done';
          });
        }
      } # while
    }
  });
} # run_resolve_https

sub load () {
  return Promise->all ([
    load_states,
  ]);
} # load

sub save () {
  return Promise->all ([
    save_states,
  ]);
} # save

sub run ($$) {
  my $code = shift;
  my $signal = shift;
  warn "Stop: Ctrl-C\n";
  my $start = time;
  return load->then (sub {
    return $code->();
  })->then (sub {
    return if $signal->aborted;
    return save;
  })->then (sub {
    return if $signal->aborted;
    return generate_sorted_indexes_0;
  })->then (sub {
    return run_resolve_https ($signal);
  })->then (sub {
    return save;
  })->then (sub {
    return generate_sorted_indexes;
  })->then (sub {
    my $end = time;
    warn sprintf "\nElapsed: %ds\n", $end - $start;
    reset_count;
  })->finally (sub {
    return close_clients;
  })->to_cv->recv;
} # run

sub keyword ($$) {
  my ($word, $signal) = @_;
  return get_h ('keyword', 'jp', word => $word, signal => $signal)->then (sub {
    return if $signal->aborted;
    return save;
  })->then (sub {
    return if $signal->aborted;
    return get_h ('keyword', 'com', word => $word, signal => $signal);
  })->then (sub {
    return if $signal->aborted;
    return save;
  });
} # keyword

sub user ($$;%) {
  my ($name, $signal, %args) = @_;
  return Promise->resolve->then (sub {
    return if $signal->aborted;
    return get_users ('favorite', name => $name, signal => $signal);
  })->then (sub {
    return if $signal->aborted;
    return get_users ('fan', name => $name, signal => $signal);
  })->then (sub {
    return if $signal->aborted;
    return get_favorite_keywords (name => $name, signal => $signal);
  })->then (sub {
    return if $signal->aborted;
    return save;
  })->then (sub {
    return if $signal->aborted;
    return get_n ('user', name => $name, signal => $signal,
                  skip_recently_checked => $args{skip_some},
                  skip_not_active => $args{skip_some});
  })->then (sub {
    return if $signal->aborted;
    return get_h ('user', 'com', name => $name, signal => $signal);
  })->then (sub {
  #  return if $signal->aborted;
  #  return get_n ('user2', name => $name, signal => $signal);
  #})->then (sub {
    return if $signal->aborted;
    return save;
  })->then (sub {
    return if $signal->aborted;
    return keyword ('id:'.$name, $signal) if $args{with_keyword};
  });
} # user

sub antenna ($$) {
  my ($name, $signal) = @_;
  return Promise->resolve->then (sub {
    return if $signal->aborted;
    return user ($name, $signal, with_keyword => 1);
  })->then (sub {
    return if $signal->aborted;
    return state_graph 'user', name => $name;
  })->then (sub {
    return if $signal->aborted;
    my $sh = $_[0];
    return Promise->resolve->then (sub {
      my $names = [keys %{$sh->{graphs}->{favorite_user} or {}}];
      my $n = 0;
      return promised_for {
        return if $signal->aborted;
        my $name = shift;
        print STDERR sprintf "\x0D%s\x0DUser %d/%d ", " " x 20, ++$n, 0+@$names;
        return user ($name, $signal, with_keyword => 1)->then (sleeper $signal);
      } $names;
    })->then (sub {
      return if $signal->aborted;
      my $words = [keys %{$sh->{graphs}->{favorite_keyword} or {}}];
      my $n = 0;
      return promised_for {
        return if $signal->aborted;
        my $word = shift;
        print STDERR sprintf "\x0D%s\x0DKeyword %d/%d ", " " x 20, ++$n, 0+@$words;
        return keyword ($word, $signal)->then (sleeper $signal);
      } $words;
    });
  });
} # antenna

sub public ($) {
  my $signal = shift;
  return Promise->resolve->then (sub {
    #return get_h ('public', 'jp', signal => $signal);
    return get_n ('public', signal => $signal);
  })->then (sub {
    return if $signal->aborted;
    return get_h ('public', 'com', signal => $signal);
  });
} # public

sub auto ($) {
  my $signal = shift;
  return Promise->resolve->then (sub {
    return if $signal->aborted;
    print STDERR "public skipped in debug mode\n" if $DEBUG;
    return public ($signal) unless $DEBUG;
  })->then (sub {
    return if $signal->aborted;
    my $users_txt_path = $DataPath->child ('indexes', 'users.txt');
    my $all = 0;
    {
      my $file = $users_txt_path->openr;
      $all++ while <$file>;
    }
    my $run = sub {
      my $phase = shift;
      return if $signal->aborted;
      my $n = 0;
      my $file = $users_txt_path->openr;
      return promised_until {
        my $line = <$file>;
        return 'done' if not defined $line;
        return 'done' if $signal->aborted;
        if ($line =~ m{^([0-9A-Za-z\@_-]+)$}) {
          my $url_name = $1;
          print STDERR sprintf "\x0D%s\x0D[$phase] User %d/%d ",
              " " x 20, ++$n, $all;
          return user ($url_name, $signal,
                       skip_some => ($phase == 1 or $phase == 2))->then (sleeper $signal);
        }
      };
    }; # $run
    return promised_for {
      return if $signal->aborted;
      my $phase = shift;
      return Promise->resolve->then (sub {
        generate_sorted_indexes_u;
      })->then (sub {
        return $run->($phase);
      });
    } [1, 2, 3];
  });
} # auto

sub main (@) {
  my $command = shift // '';
  my $ac = AbortController->new;
  local $SIG{INT} = local $SIG{TERM} = sub {
    warn "Terminating...\n";
    $ac->abort;
    delete $SIG{INT};
    delete $SIG{TERM};
  };
  my $signal = $ac->signal;
  if ($command eq 'user') {
    my $name = shift // '';
    die "Usage: har $command name" unless length $name;
    run (sub {
      return user ($name, $signal);
    }, $signal);
  } elsif ($command eq 'keyword') {
    my $word = decode_web_utf8 (shift // '');
    die "Usage: har $command word" unless length $word;
    run (sub {
      return keyword ($word, $signal);
    }, $signal);
  } elsif ($command eq 'antenna') {
    my $name = shift // '';
    die "Usage: har $command name" unless length $name;
    run (sub {
      return antenna ($name, $signal);
    }, $signal);
  } elsif ($command eq 'public') {
    run (sub {
      return public ($signal);
    }, $signal);
  } elsif ($command eq 'auto') {
    run (sub {
      return auto ($signal);
    }, $signal);
  } elsif ($command eq 'version') {
    print path (__FILE__)->parent->parent->child ('rev')->slurp;
  } else {
    die "Usage: har command\n";
  }
} # main

main (@ARGV);

=head1 LICENSE

Copyright 2019 Wakaba <wakaba@suikawiki.org>.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public
License along with this program.  If not, see
<https://www.gnu.org/licenses/>.

=cut
