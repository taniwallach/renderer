package RenderApp::Controller::Render;
use Mojo::Base 'Mojolicious::Controller';
use Mojo::UserAgent;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::JWT;
use Data::Dumper;

sub problem {
  my $c = shift;
  my $isLibreText = 0;
  my $problemJWT;
  my $sessionJWT;
  my $file_path = $c->param('sourceFilePath'); # || $c->session('filePath');
  my $random_seed = $c->param('problemSeed');

  my %inputs_ref = WeBWorK::Form->new_from_paramable($c->req)->Vars;
  $inputs_ref{formURL} ||= $c->app->config('form');
  $inputs_ref{baseURL} ||= $c->app->config('url');

  if (defined($c->req->param('problemJWT'))) {
    $problemJWT = $c->req->param('problemJWT');
    my $claims = Mojo::JWT->new(secret => $ENV{JWTsecret})->decode($problemJWT);
    $sessionJWT = Mojo::JWT->new(claims=>%inputs_ref, secret=>$ENV{JWTsecret})->encode;
    $isLibreText = 1;
    $file_path = $claims->{webwork}{sourceFilePath};
    $random_seed = $claims->{webwork}{problemSeed};
    $inputs_ref{sourceFilePath} = $file_path;
    $inputs_ref{problemSeed} = $random_seed;
  }

  my $problem = $c->newProblem({log => $c->log, read_path => $file_path, random_seed => $random_seed});
  return $c->render(json => $problem->errport(), status => $problem->{status}) unless $problem->success();
  $inputs_ref{sourceFilePath} = $problem->{read_path}; # in case the path was updated...

  my @errs = checkInputs(\%inputs_ref);
  if (@errs) {
    my $err_log = "Form data submitted for ".$inputs_ref{sourceFilePath}." contained errors:\n";
    $err_log .= join "\n", @errs;
    $c->log->warn($err_log);
  }

  # consider passing the problem object alongside the inputs_ref - this will become unnecessary
  my $ww_return_json = $problem->render(\%inputs_ref);
  my $ww_return_hash = decode_json($ww_return_json);

  $ww_return_hash->{debug}->{render_warn} = \@errs;

  if ($isLibreText) {
    my $scoreHash = {};
    my $answerNum =0;
    foreach my $ans_id (@{$ww_return_hash->{flags}{ANSWER_ENTRY_ORDER}}) {
      $answerNum++;  # start with 1, this is also the row number
      $scoreHash->{$answerNumber} = {
        ans_id => $ans_id,
        answer => %{$ww_return_hash->{answers}{$ans_id}} // (),
        score => $rh_answers->{answers}{$ans_id}{score} // 0,
      };
    }
    my $scoreJSON = encode_json($scoreHash);
    
    my %responseHash = {
      problemJWT => $problemJWT,
      sessionJWT => $sessionJWT,
      score => %{$scoreHash}
    };
    my $answerJWT = Mojo::JWT->new(claims=>%responseHash, secret=>$ENV{JWTsecret});

    my $ua  = Mojo::UserAgent->new;
    my $response = $ua->post($ENV{JWTanswerURL}, {
      'Accept' => 'application/json',
      'Authorization' => "Bearer $answerJWT",
      'Host' => $ENV{JWTanswerHost},

    });
    warn "A wild `LibreText` has appeared! --response: \n";
    warn Data::Dumper($response);
  }

  $c->respond_to(
    html => { text => $ww_return_hash->{renderedHTML}},
    json => { json => $ww_return_hash }
  );
}

sub checkInputs {
  my $inputs_ref = shift;
  my @errs;
  while (my ($k, $v) = each %$inputs_ref) {
    next unless $v;
    if ($v =~ /[^\x01-\x7F]/) {
      my $err = "UNICODE: $k contains nonstandard character(s):";
      while ($v =~ /([^\x00-\x7F])/g) {
        $err .= ' "'.$1.'" as '.sprintf("\\u%04x", ord($1));
      }
      if ( $v =~ /\x00/ ) {
        $err .= " NUL byte -- creating array.";
        my @v_array = split(/\x00/, $v);
        $inputs_ref->{$k} = \@v_array;
      }
      push @errs, $err;
    }
  }
  return @errs;
}

1;
