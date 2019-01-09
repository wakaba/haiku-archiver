use strict;
use warnings;
use Path::Tiny;
use AbortController;
use Promise;
use Promised::Flow;
use Promised::File;
use Web::URL;
use JSON::PS;
use Web::Transport::BasicClient;

my $DataPath = path (__FILE__)->parent->parent->child ('data');

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

sub validate_name ($) {
  my $name = shift;
  die "Unexpected name |$name|" unless $name =~ m{\A[0-9A-Za-z\@_-]+\z};
} # validate_name

{
  my $Indexes = {};
  
  sub index_user (%) {
    my %args = @_;
    
    validate_name $args{url_name};
    my $item = $Indexes->{users}->{url_names}->{$args{url_name}} ||= {};

    if (defined $args{followers_count}) {
      $item->{followers_count} = $args{followers_count};
    }
  } # index_user

  sub index_target (%) {
    my %args = @_;

    if (defined $args{url_name}) {
      validate_name $args{url_name};
      if ($args{url_name} =~ m{\@h$}) {
        $Indexes->{keywords}->{$args{word}}->{url_name} = $args{url_name};
        $Indexes->{keywords}->{$args{word}}->{word} = $args{word};
      } elsif ($args{url_name} =~ m{^([0-9]+)\@asin$}) {
        $Indexes->{asins}->{$1}->{url_name} = $args{url_name};
        $Indexes->{asins}->{$1}->{word} = $args{word};
      } else {
        index_user url_name => $args{url_name};
      }
    } else {
      $Indexes->{keywords}->{$args{word}}->{word} = $args{word};
    }
  } # index_target

  sub index_thread_entry (%) {
    my %args = @_;
    $Indexes->{$args{type} . '_entries_' . $args{tld}}->{threads}->{$args{name}}->{$args{eid}}
        = [$args{timestamp}, $args{user}];
  } # index_thread_entry

  sub index_reply_entry (%) {
    my %args = @_;
    $Indexes->{'reply_entries'}->{children}->{$args{parent_eid}}->{$args{child_eid}}
        = [$args{timestamp}, $args{child_user}, $args{parent_user}];
  } # index_reply_entry

  my $IndexNames = [qw(users keywords asins
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
    } $IndexNames;
  } # load_indexes

  sub save_indexes () {
    return promised_for {
      my $name = shift;
      my $path = $DataPath->child ('indexes', $name . '.json');
      return Promised::File->new_from_path ($path)->write_byte_string (perl2json_bytes $Indexes->{$name});
    } $IndexNames;
  } # save_indexes
}

sub save_entries ($$) {
  my ($type, $items) = @_;
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
        word => $item->{target}->{word};
    index_target
        word => $item->{source};

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
        timestamp => $ts->to_unix_number;
    
    my $path = $DataPath->child ('entries')
        ->child ($item->{user}->{screen_name})
        ->child ($item->{id} . '.' . $type . '.json');
    my $file = Promised::File->new_from_path ($path);

    return $file->is_file->then (sub {
      return if $_[0]; # skip
      return $file->write_byte_string (perl2json_bytes $item);
    });
  } $items;
} # save_entries

sub get_h ($$%) {
  my ($type, $tld, %args) = @_;
  my $client = Web::Transport::BasicClient->new_from_url
      (Web::URL->parse_string ($tld eq 'com' ? 'http://h.hatena.com' : "http://h.hatena.ne.jp"));
  my $page = 1;
  return ((promised_until {
    return with_retry (sub {
      return $client->request (
        path => [
          'api', 'statuses',
          ($type eq 'user' ? ($type . '_timeline', $args{name} . '.json')
                           : ($type . '_timeline.json')),
        ],
        params => {
          body_formats => 'haiku',
          count => 200,
          page => $page,
        },
      )->then (sub {
        my $res = $_[0];
        die $res unless $res->status == 200;
        return json_bytes2perl $res->body_bytes;
      });
    }, $args{signal})->then (sub {
      my $json = $_[0];
      return 'done' if $args{signal}->aborted and not defined $json;
      if (ref $json eq 'ARRAY') {
        return 'done' unless @$json;

        $_->{tld} = $tld for @$json;
        return Promise->all ([
          save_entries ('h', $json),
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
  })->finally (sub {
    return $client->close;
  }));
} # get_h

sub run ($) {
  my $code = shift;
  return load_indexes->then (sub {
    return $code->();
  })->then (sub {
    return save_indexes;
  })->to_cv->recv;
} # run

sub main (@) {
  my $command = shift // '';
  my $ac = AbortController->new;
  $SIG{INT} = $SIG{TERM} = sub {
    warn "Aborted...\n";
    $ac->abort;
    delete $SIG{INT};
    delete $SIG{TERM};
  };
  my $signal = $ac->signal;
  if ($command eq 'user') {
    my $name = shift // '';
    die "Usage: har user name" unless length $name;
    run (sub {
      return get_h ('user', 'jp', name => $name, signal => $signal)->then (sub {
        return save_indexes;
      })->then (sub {
        return get_h ('user', 'com', name => $name, signal => $signal);
      });
    });
  } elsif ($command eq 'public') {
    run (sub {
      return get_h ('public', 'jp', signal => $signal);
    });
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
