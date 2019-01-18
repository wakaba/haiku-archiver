use strict;
use warnings;
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

my $Counts = {entries => 0, users => 0, keywords => 0};
sub reset_count () {
  warn sprintf "\nNew entries: %d, users: %d\n",
      $Counts->{entries}, $Counts->{users};
  $Counts = {entries => 0, users => 0, keywords => 0};
} # reset_count
my $CountInterval = 60;
my $timer = AE::timer $CountInterval, $CountInterval, sub {
  reset_count;
};

sub debug_req ($) {
  my $req = shift;
  if ($ENV{DEBUG}) {
    print STDERR "\r", $req->{url}->stringify if defined $req->{url};
    print STDERR "\r", join ("/", @{$req->{path}}) if defined $req->{path};
  }
  return %$req;
} # debug_req

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
    return Promise->resolve->then ($code)->then (sub {
      $return = $_[0];
      return 'done';
    }, sub {
      my $e = $_[0];
      die $e if $n++ > 5;
      warn "Failed ($e); retrying ($n)...\n";
      return not 'done';
    });
  })->then (sub {
    return $return;
  }));
} # with_retry

sub sleeper ($$) {
  my $n = shift;
  my $signal = shift;
  return sub {
    return if $signal->aborted;
    if (($n % 20) == 0) {
      warn "Sleep (75)\n" if $ENV{DEBUG};
      return promised_sleep 75;
    } elsif (($n % 10) == 0) {
      warn "Sleep (25)\n" if $ENV{DEBUG};
      return promised_sleep 25;
    } else {
      return promised_sleep 5;
    }
  };
} # sleeper

sub validate_name ($) {
  my $name = shift;
  die "Unexpected name |$name|" unless $name =~ m{\A[0-9A-Za-z\@_-]+\z};
} # validate_name

my $Indexes = {};
my $Graphs = {};
{
  
  sub index_user (%) {
    my %args = @_;
    
    validate_name $args{url_name};

    $Counts->{users}++ unless defined $Indexes->{users}->{url_names}->{$args{url_name}};
    
    my $item = $Indexes->{users}->{url_names}->{$args{url_name}} ||= {};

    if (defined $args{followers_count}) {
      $item->{followers_count} = $args{followers_count};
      if ($item->{followers_count} == 0) {
        $Indexes->{users}->{url_names}->{$args{url_name}}->{fan_user_updated} //= time;
      }
    }
  } # index_user

  sub index_target (%);
  sub index_target (%) {
    my %args = @_;

    my $word;
    if (defined $args{url_name}) {
      validate_name $args{url_name};
      if ($args{url_name} =~ m{\@(?:h)$}) {
        $word = $args{word} // $args{title};
        #$Counts->{keywords}++ unless defined $Indexes->{keywords}->{word}->{$word};
        #$Indexes->{keywords}->{word}->{$word}->{url_name} = $args{url_name};
        #$Indexes->{keywords}->{word}->{$word}->{word} = $word;
      } elsif ($args{url_name} =~ m{^(.+)\@(?:asin)$}) {
        #$Counts->{keywords}++ unless defined $Indexes->{asin}->{$1};
        $Indexes->{asin}->{$1} = 1;
      } elsif ($args{url_name} =~ m{\@(?:http)$}) {
        if (defined $args{word}) {
          #$Counts->{keywords}++ unless defined $Indexes->{keywords}->{word}->{$word};
          $Indexes->{http}->{$args{word}} = $args{url_name};
          $Indexes->{http_url_name}->{$args{url_name}}->{word} = $args{word};
          delete $Indexes->{http_url_name}->{$args{url_name}}->{sample};
        } else {
          unless (defined $Indexes->{http_url_name}->{$args{url_name}}->{word}) {
            $Indexes->{http_url_name}->{$args{url_name}}->{sample} = $args{eidtld}
                if defined $args{eidtld};
          }
          return;
        }
      } else {
        index_user url_name => $args{url_name};
        return;
      }
    } else {
      $word = $args{word};
      #$Counts->{keywords}++ unless defined $Indexes->{keywords}->{word}->{$word};
      #$Indexes->{keywords}->{word}->{$word}->{word} = $word;
    }

    for (qw(followers_count entry_count entry_count_jp entry_count_com)) {
      $Indexes->{keyword_info}->{$word}->{$_} = $args{$_} if defined $args{$_};
    }

    for (@{$args{related_keywords} or []}) {
      index_target word => $_;
      $Graphs->{related_keyword}->{$word}->{$_} = 1;
    }
  } # index_target

  sub index_entry (%) {
    my %args = @_;
    $Counts->{entries}++ unless defined $Indexes->{entries}->{eid}->{$args{eid}};
    #$Indexes->{entries}->{eid}->{$args{eid}} = [$args{timestamp}, $args{user}];
  } # index_entry

  sub index_thread_entry (%) {
    my %args = @_;
    #$Indexes->{$args{type} . '_entries_' . $args{tld}}->{threads}->{$args{tld}}->{$args{eid}}
    #    = [$args{timestamp}, $args{user}];
  } # index_thread_entry

  sub index_reply_entry (%) {
    my %args = @_;
    #$Indexes->{'reply_entries'}->{children}->{$args{parent_eid}}->{$args{child_eid}}
    #    = [$args{timestamp}, $args{child_user}, $args{parent_user}];
  } # index_reply_entry

  my $TargetIndexNames = [qw(users
                             asin http http_url_name keyword_info)]; # keywords
  my $ThreadIndexNames = [qw(entries
                             public_entries_jp public_entries_com
                             user_entries_jp target_entries_jp
                             user_entries_com target_entries_com
                             reply_entries)];

  sub load_indexes () {
    return promised_for {
      my $name = shift;
      my $path = $DataPath->child ('indexes', $name . '.json');
      my $file = Promised::File->new_from_path ($path);
      return $file->is_file->then (sub {
        return {} unless $_[0];
        return $file->read_byte_string->then
            (sub { return json_bytes2perl $_[0] });
      })->then (sub {
        $Indexes->{$name} = $_[0];
      });
    } [@$TargetIndexNames, @$ThreadIndexNames];
  } # load_indexes

  sub save_target_indexes () {
    return promised_for {
      my $name = shift;
      my $path = $DataPath->child ('indexes', $name . '.json');
      return Promised::File->new_from_path ($path)->write_byte_string (perl2json_bytes $Indexes->{$name});
    } $TargetIndexNames;
  } # save_target_indexes

  sub save_thread_indexes () {
    return promised_for {
      my $name = shift;
      my $path = $DataPath->child ('indexes', $name . '.json');
      return Promised::File->new_from_path ($path)->write_byte_string (perl2json_bytes $Indexes->{$name});
    } $ThreadIndexNames;
  } # save_thread_indexes
}

{
  my $States = {};
  my $StateNames = [qw(user keyword asin http public)];
  
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

  sub state_h ($$;%) {
    my ($type, $tld, %args) = @_;
    my $state;
    if ($type eq 'user') {
      $state = $States->{user}->{$args{name}}->{'h_' . $tld} ||= {};
    } elsif ($type eq 'keyword') {
      if ($args{word} =~ /^asin:/i) {
        $state = $States->{asin}->{$args{word}}->{'h_' . $tld} ||= {};
      } elsif ($args{word} =~ /^http:/i) {
        $state = $States->{http}->{$args{word}}->{'h_' . $tld} ||= {};
      } else {
        $state = $States->{keyword}->{$args{word}}->{'h_' . $tld} ||= {};
      }
    } elsif ($type eq 'public') {
      $state = $States->{public}->{'h_' . $tld} ||= {};
    } else {
      die "Bad type |$type|";
    }
    return $state;
  } # state_h

  sub state_n ($;%) {
    my ($type, %args) = @_;
    my $state;
    if ($type eq 'user') {
      $state = $States->{user}->{$args{name}}->{n} ||= {};
    } elsif ($type eq 'user2') {
      $state = $States->{user}->{$args{name}}->{n2} ||= {};
    } elsif ($type eq 'public') {
      $state = $States->{public}->{n_jp} ||= {};
    } else {
      die "Bad type |$type|";
    }
    return $state;
  } # state_n

  sub state_graph ($;%) {
    my ($type, %args) = @_;
    my $state;
    if ($type eq 'user') {
      $state = $States->{user}->{$args{name}}->{graph} ||= {};
    } else {
      die "Bad type |$type|";
    }
    return $state;
  } # state_graph
}

{
  my $GraphNames = [qw(favorite_user fan_user favorite_keyword
                       related_keyword)];
  
  sub load_graphs () {
    return promised_for {
      my $name = shift;
      my $path = $DataPath->child ('graphs', $name . '.json');
      my $file = Promised::File->new_from_path ($path);
      return $file->is_file->then (sub {
        return {} unless $_[0];
        return $file->read_byte_string->then
            (sub { return json_bytes2perl $_[0] });
      })->then (sub {
        $Graphs->{$name} = $_[0];
      });
    } $GraphNames;
  } # load_graphs

  sub save_graphs () {
    return promised_for {
      my $name = shift;
      my $path = $DataPath->child ('graphs', $name . '.json');
      return Promised::File->new_from_path ($path)->write_byte_string (perl2json_bytes $Graphs->{$name});
    } $GraphNames;
  } # save_graphs
}

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
        url_name => $item->{user}->{screen_name},
        followers_count => $item->{user}->{followers_count};
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
    if (length $item->{in_reply_to_status_id}) {
      index_reply_entry
          parent_user => $item->{user}->{screen_name},
          parent_eid => $item->{id},
          child_user => $item->{in_reply_to_user_id},
          child_eid => $item->{in_reply_to_status_id},
          timestamp => $ts->to_unix_number;
    }
    for (@{$item->{replies}}) {
      index_user
          url_name => $_->{user}->{screen_name};
    }

    index_thread_entry
        tld => $item->{tld},
        type => 'user',
        name => $item->{user}->{screen_name},
        user => $item->{user}->{screen_name},
        eid => $item->{id},
        timestamp => $ts->to_unix_number;
    index_thread_entry
        tld => $item->{tld},
        type => 'target',
        name => $item->{target}->{url_name},
        user => $item->{user}->{screen_name},
        eid => $item->{id},
        timestamp => $ts->to_unix_number
        if defined $item->{target}->{url_name};
    if (defined $item->{target}->{url_name} and
        $item->{target}->{url_name} =~ m{\@(?:h|asin|http)$}) {
      index_thread_entry
          tld => $item->{tld},
          type => 'public',
          user => $item->{user}->{screen_name},
          eid => $item->{id},
          timestamp => $ts->to_unix_number;
    }

    index_entry
        user => $item->{user}->{screen_name},
        eid => $item->{id},
        timestamp => $ts->to_unix_number;

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
        title => $item->{target}->{display_name},
        eidtld => [$item->{eid}, $item->{tld}]
        if defined $item->{target}->{display_name};
    index_target
        url_name => $item->{source_target}->{url_name},
        title => $item->{source_target}->{display_name}
        if defined $item->{source_target}->{display_name};

    if (defined $item->{reply_to_author}) {
      index_user
          url_name => $item->{reply_to_author}->{url_name};
    }
    if (length $item->{reply_to_eid}) {
      index_reply_entry
          parent_user => $item->{author}->{url_name},
          parent_eid => $item->{eid},
          child_user => $item->{reply_to_author}->{url_name},
          child_eid => $item->{reply_to_eid},
          timestamp => $item->{created_on};
    }

    index_thread_entry
        tld => $item->{tld},
        type => 'user',
        name => $item->{author}->{url_name},
        user => $item->{author}->{url_name},
        eid => $item->{eid},
        timestamp => $item->{created_on};
    index_thread_entry
        tld => $item->{tld},
        type => 'target',
        name => $item->{target}->{url_name},
        user => $item->{author}->{url_name},
        eid => $item->{eid},
        timestamp => $item->{created_on}
        if defined $item->{target}->{url_name};
    if (defined $item->{target}->{url_name} and
        $item->{target}->{url_name} =~ m{\@(?:h|asin|http)$}) {
      index_thread_entry
          tld => $item->{tld},
          type => 'public',
          user => $item->{author}->{url_name},
          eid => $item->{eid},
          timestamp => $item->{created_on};
    }

    index_entry
        user => $item->{author}->{url_name},
        eid => $item->{eid},
        timestamp => $item->{created_on};
    
    return write_entry $item->{author}->{url_name}, $item->{eid}, 'n', $item;
  } $items;
} # save_n_entries

sub get_h ($$%) {
  my ($type, $tld, %args) = @_;
  my $client = Web::Transport::BasicClient->new_from_url
      (Web::URL->parse_string ($tld eq 'com' ? 'http://h.hatena.com' : "http://h.hatena.ne.jp"));
  my $state = state_h $type, $tld, name => $args{name}, word => $args{word};
  my $since;
  return if $tld eq 'com' and $state->{no_more_older};
  if ($state->{no_more_older} and defined $state->{latest_timestamp}) {
    $since = Web::DateTime->new_from_unix_time ($state->{latest_timestamp})->to_http_date_string;
  }
  my $page = 1;
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
          page => $page,
          ($type eq 'keyword' ? (word => $args{word}) : ()),
          since => $since,
        },
      })->then (sub {
        my $res = $_[0];
        die $res unless $res->status == 200;
        return json_bytes2perl $res->body_bytes;
      });
    }, $args{signal})->then (sub {
      my $json = $_[0];
      return 'done' if $args{signal}->aborted and not defined $json;
      if (ref $json eq 'ARRAY') {
        return 'done' unless @$json;

        my $ts = Web::DateTime::Parser->parse_global_date_and_time_string
            ($json->[0]->{created_at});
        $state->{latest_timestamp} = $ts->to_unix_number
            if not defined $state->{latest_timestamp} or
               $state->{latest_timestamp} < $ts->to_unix_number;

        $_->{tld} = $tld for @$json;
        return Promise->all ([
          save_h_entries ($json),
        ])->then (sub {
          return 'done' if $page++ > 100;
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
    $state->{no_more_older} = 1;
  })->finally (sub {
    return $client->close;
  }));
} # get_h

sub get_n ($%) {
  my ($type, %args) = @_;
  my $client = Web::Transport::BasicClient->new_from_url
      (Web::URL->parse_string ("http://h.hatena.ne.jp"));
  my $state = state_n $type, name => $args{name};
  return if $type eq 'user2' and $state->{no_more_newer};
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
  return ((promised_until {
    my $time = time;
    return with_retry (sub {
      debug_req $req;
      return $client->request (%$req)->then (sub {
        my $res = $_[0];
        die $res unless $res->status == 200;
        return json_bytes2perl $res->body_bytes;
      });
    }, $args{signal})->then (sub {
      my $json = $_[0];
      return 'done' if $args{signal}->aborted and not defined $json;
      if (ref $json eq 'HASH') {
        $state->{newer_url} = $json->{newer_url};
        $state->{last_checked} = $time;
        unless (@{$json->{items}}) {
          $state->{no_more_newer} = 1 if $type eq 'user2';
          return 'done';
        }

        return Promise->all ([
          save_n_entries ($json->{items}),
        ])->then (sub {
          my $ts = Web::DateTime->new_from_unix_time ($json->{items}->[-1]->{created_on});
          print STDERR "\x0D" . $ts->to_global_date_and_time_string;
          return 'done' if $args{signal}->aborted;
          $req = {
            url => Web::URL->parse_string ($json->{newer_url}),
          };
          $n++;
          return 'done' if $n > 20 and not $type eq 'public';
          return 'done' if $n > 900000 and $type eq 'public';
          return save ()->then (sub {
            return not 'done';
          });
        });
      } else {
        die "Server returns an unexpected response";
      }
    });
  })->finally (sub {
    warn "get_n done\n" if $ENV{DEBUG};
    return $client->close;
  }));
} # get_n

sub get_users ($$%) {
  my ($type, %args) = @_;

  my $state = state_graph 'user', name => $args{name};
  my $ts = $state->{$type . '_user_updated'};
  return if defined $ts;
  
  my $client = Web::Transport::BasicClient->new_from_url
      (Web::URL->parse_string ("http://h.hatena.ne.jp"));
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
              url_name => $item->{screen_name},
              followers_count => $item->{followers_count};
          $Graphs->{$type . '_user'}->{$args{name}}->{$item->{screen_name}} = 1;
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
  })->then (sub {
    return $client->close;
  }));
} # get_users

sub get_favorite_keywords ($%) {
  my (%args) = @_;

  my $state = state_graph 'user', name => $args{name};
  my $ts = $state->{favorite_keyword_updated};
  return if defined $ts;
  
  my $client = Web::Transport::BasicClient->new_from_url
      (Web::URL->parse_string ("http://h.hatena.ne.jp"));
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
        die $res unless $res->status == 200;
        return json_bytes2perl $res->body_bytes;
      });
    }, $args{signal})->then (sub {
      my $json = $_[0];
      return 'done' if $args{signal}->aborted and not defined $json;
      if (ref $json eq 'ARRAY') {
        return 'done' unless @$json;

        for my $item (@$json) {
          index_target
              word => $item->{word},
              url_name => $item->{url_name},
              followers_count => $item->{followers_count},
              entry_count => $item->{entry_count},
              entry_count_jp => $item->{entry_count_jp},
              entry_count_com => $item->{entry_count_com},
              related_keywords => $item->{related_keywords};
          $Graphs->{favorite_keyword}->{$args{name}}->{$item->{word}} = 1;
        }

        return 'done' if @$json != 100 and $prev_count == @$json;
        $prev_count = @$json;

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
    $state->{favorite_keyword_updated} = time;
  })->then (sub {
    return $client->close;
  }));
} # get_favorite_keywords

sub get_entry ($$$) {
  my ($tld, $eid, $signal) = @_;
  my $client = Web::Transport::BasicClient->new_from_url
      (Web::URL->parse_string ("http://h.hatena.ne.jp"));
  return ((promised_until {
    return with_retry (sub {
      return $client->request (debug_req {
        path => ['api', 'statuses', 'show', $eid . '.json'],
        params => {
          body_formats => 'haiku',
        },
      })->then (sub {
        my $res = $_[0];
        die $res unless $res->status == 200;
        return json_bytes2perl $res->body_bytes;
      });
    }, $signal)->then (sub {
      my $json = $_[0];
      return 'done' if $signal->aborted and not defined $json;
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
  })->finally (sub {
    return $client->close;
  }));
} # get_entry

sub get_target_entries ($) {
  my $signal = shift;
  return promised_for {
    my $url_name = shift;
    my $item = $Indexes->{http_url_name}->{$url_name};
    if (defined $item->{sample}) { # [eid, tld]
      return get_entry ($item->{sample}->[1], $item->{sample}->[0], $signal);
    }
  } [keys %{$Indexes->{http_url_name} or {}}];
} # get_target_entries

sub load () {
  return Promise->all ([
    load_indexes,
    load_graphs,
    load_states,
  ]);
} # load

sub save () {
  return Promise->all ([
    save_target_indexes,
    save_graphs,
    save_states,
  ]);
} # save

sub save_all () {
  return Promise->all ([
    save,
    save_thread_indexes,
  ]);
} # save_all

sub run ($) {
  my $code = shift;
  warn "Stop: Ctrl-C\n";
  my $start = time;
  return load->then (sub {
    return $code->();
  })->then (sub {
    return save_all;
  })->then (sub {
    my $end = time;
    warn sprintf "\nElapsed: %ds\n", $end - $start;
    reset_count;
  })->to_cv->recv;
} # run

sub user ($$) {
  my ($name, $signal) = @_;
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
    return get_n ('user', name => $name, signal => $signal);
  })->then (sub {
    return if $signal->aborted;
    return get_n ('user2', name => $name, signal => $signal);
  })->then (sub {
    return if $signal->aborted;
    return get_target_entries ($signal);
  })->then (sub {
    return if $signal->aborted;
    return get_h ('user', 'com', name => $name, signal => $signal);
  })->then (sub {
    return if $signal->aborted;
    return save;
  });
  #return get_h ('user', 'jp', name => $name, signal => $signal)->then (sub {
} # user

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

sub antenna ($$) {
  my ($name, $signal) = @_;
  return Promise->resolve->then (sub {
    return if $signal->aborted;
    return user ($name, $signal);
  })->then (sub {
    return if $signal->aborted;
    my $names = [keys %{$Graphs->{favorite_user}->{$name} or {}}];
    my $n = 0;
    return promised_for {
      return if $signal->aborted;
      my $name = shift;
      print STDERR sprintf "\x0D%s\x0DUser %d/%d ", " " x 20, ++$n, 0+@$names;
      return user ($name, $signal)->then (sleeper $n, $signal);
    } $names;
  })->then (sub {
    return if $signal->aborted;
    my $words = [keys %{$Graphs->{favorite_keyword}->{$name} or {}}];
    my $n = 0;
    return promised_for {
      return if $signal->aborted;
      my $word = shift;
      print STDERR sprintf "\x0D%s\x0DKeyword %d/%d ", " " x 20, ++$n, 0+@$words;
      return keyword ($word, $signal)->then (sleeper $n, $signal);
    } $words;
  });
} # antenna

sub public ($) {
  my $signal = shift;
  return Promise->resolve->then (sub {
    #return get_h ('public', 'jp', signal => $signal);
    return get_n ('public', signal => $signal);
  })->then (sub {
    return if $signal->aborted;
    return get_target_entries ($signal);
  })->then (sub {
    return if $signal->aborted;
    return get_h ('public', 'com', signal => $signal);
  });
} # public

sub auto ($) {
  my $signal = shift;
  return Promise->resolve->then (sub {
    return if $signal->aborted;
    return public ($signal);
  })->then (sub {
    return if $signal->aborted;
    my $n = 0;
    return promised_wait {
      return 'done' if $signal->aborted;

      my $name;
      my $last_checked = time;
      my $min_done_last_checked = time - 24*60*60;
      for my $x (keys %{$Indexes->{users}->{url_names}}) {
        my $state = state_n 'user', $x;
        if (not defined $state->{n}->{last_checked}) {
          $name = $x;
          last;
        } elsif ($state->{n}->{last_checked} >= $min_done_last_checked) {
          #
        } elsif ($state->{n}->{last_checked} < $last_checked) {
          $last_checked = $state->{n}->{last_checked};
          $name = $x;
        }
      }
      return 'done' unless defined $name;

      my $all = 0+keys %{$Indexes->{users}->{url_names}};
      
      print STDERR sprintf "\x0D%s\x0DUser %d/%d ", " " x 20, ++$n, $all;
      return user ($name, $signal)->then (sleeper $n, $signal);
    };
  });
} # auto

sub main (@) {
  my $command = shift // '';
  my $ac = AbortController->new;
  $SIG{INT} = $SIG{TERM} = sub {
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
    });
  } elsif ($command eq 'keyword') {
    my $word = decode_web_utf8 (shift // '');
    die "Usage: har $command word" unless length $word;
    run (sub {
      return keyword ($word, $signal);
    });
  } elsif ($command eq 'antenna') {
    my $name = shift // '';
    die "Usage: har $command name" unless length $name;
    run (sub {
      return antenna ($name, $signal);
    });
  } elsif ($command eq 'public') {
    run (sub {
      return public ($signal);
    });
  } elsif ($command eq 'auto') {
    run (sub {
      return auto ($signal);
    });
  } else {
    die "Usage: har command\n";
  }
  undef $ac;
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
