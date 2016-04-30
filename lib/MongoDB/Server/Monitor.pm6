use v6.c;

use MongoDB;
use MongoDB::Server::Socket;
use MongoDB::Header;
use BSON::Document;

#-------------------------------------------------------------------------------
unit package MongoDB;

#-------------------------------------------------------------------------------
# Complete standalone and thereby thread save, to monitor a mongo server. To
# separate everything, several code sections are taken from Database, Collection
# and Wire modules with several shortcuts because the operation to get the
# information is simple.
#
# - Server object is past from the Server object to initiate the polling.
# - Read and write concern info and some other query options are not needed.
# - No server shutdown on failures. Communicate through channel.
# - Full collection name is fixed. Document and encoding is fixed.
# - No Cursor object needed. One document is pulled out directly from result.
#
# Note: Because Supplier is inherited, BUILD cannot get its named parameters.
# when a new() method is defined, Supplier gets wrong parameters. Therefore
# BUILD is replaced by monitor-init() and must be called explicitly
#
class Server::Monitor is Supplier {

  has $!server;
  has MongoDB::Server::Socket $!socket;

  has Duration $!weighted-mean-rtt .= new(0);

  # Variables to control infinite monitoring actions
  has Promise $!promise-monitor;
  has Semaphore $!server-monitor-control;
  has Int $.monitor-looptime is rw = 10;
  has Bool $!monitor-loop;
  has BSON::Document $!monitor-command;
  has BSON::Document $!monitor-result;

  #-----------------------------------------------------------------------------
  # Call before monitor-server to set the $!server object!
  # Inheriting from Supplier prevents use of proper BUILD 
  #
  method monitor-init ( :$server ) {

    $!server = $server;

    $!monitor-command .= new: (isMaster => 1);
    $!monitor-command.encode;
    $!monitor-command does MongoDB::Header;

    $!server-monitor-control .= new(1);
  }

  #-----------------------------------------------------------------------------
  method done ( ) {

    $!monitor-loop = False;
    callwith();
  }

  #-----------------------------------------------------------------------------
  method quit ( ) {

    $!monitor-loop = False;
    callwith('Monitor forced to quit');
  }

  #-----------------------------------------------------------------------------
#  method emit ( |c ) {
#
#say "Start emit: ", c.perl;
#    callsame;
#say "Done emit";
#  }

  #-----------------------------------------------------------------------------
  # Run this on a separate thread because it lasts until this program atops.
  #
  method monitor-server ( ) {

    return unless $!server-monitor-control.try_acquire;

    info-message("Start $!server.name() monitoring");
    $!promise-monitor .= start( {

        my Instant $t0;
        my Duration $rtt;
        my BSON::Document $doc;

        # As long as the server lives test it. Changes are possible when 
        # server conditions change.
        #
        $!monitor-loop = True;
        while $!monitor-loop {

          # Temporary try block to catch typos
          try {

            # Save time stamp for RTT measurement
            $t0 = now;

            # Get server info
            $doc = self!query;
            if $doc.defined {

              # Calculation of mean Return Trip Time
              $rtt = now - $t0;
              $!weighted-mean-rtt .= new(
                0.2 * $rtt + 0.8 * $!weighted-mean-rtt
              );

#say "Monitor info: ", $doc.perl;

              self.emit( {
                  ok => True,
                  monitor => $doc<documents>[0],
                  weighted-mean-rtt => $!weighted-mean-rtt
                }
              );

              info-message(
                "Weighted mean RTT: $!weighted-mean-rtt for server $!server.name()"
              );
            }
            
            else {
              self.emit( {
                  ok => False,
                  reason => 'Undefined document'
                }
              );
            }

            # Rest for a while
            sleep($!monitor-looptime);

            # Capture errors. When there are any, On older servers before
            # version 3.2 the server just stops communicating when a shutdown
            # command was given. Opening a socket will then bring us here.
            # Send ok False to mention the fact that the server is down.
            #
            CATCH {
              default {

                # Failure messages;
                #   Failed to connect: connection refused
                #   Failed to resolve host name
                #
#TODO 2016-04-30, perl6 bug, cannot do it directly in hash
                my Str $s = .message();
                self.emit( {
                    ok => False,
                    reason => $s
                  }
                );

                warn-message(
                  "Server $!server.name() error while monitoring, changing state"
                );

                # Rest for a while
                sleep($!monitor-looptime);
              }
            }
          }
        }

        info-message("Server monitoring stopped for $!server.name()");
        $!server-monitor-control.release;
      }
    );
  }

  #-----------------------------------------------------------------------------
  #
  method !query ( --> BSON::Document ) {

    # Full collection name is fixed to 'admin.$cmd'.
    ( my Buf $encoded-query, my Int $request-id) =
       $!monitor-command.encode-query( 'admin.$cmd', :number-to-return(1));

    $!socket = $!server.get-socket;
    if $!socket.defined {

      $!socket.send($encoded-query);

      # Read 4 bytes for int32 response size
      #
      my Buf $size-bytes = self!get-bytes(4);

      my Int $response-size = decode-int32( $size-bytes, 0) - 4;

      # Receive remaining response bytes from socket. Prefix it with the
      # already read bytes and decode. Return the resulting document.
      #
      my Buf $server-reply = $size-bytes ~ self!get-bytes($response-size);
      $!monitor-result = $!monitor-command.decode-reply($server-reply);

      # Assert that the request-id and response-to are the same
      fatal-message("Id in request is not the same as in the response")
        unless $request-id == $!monitor-result<message-header><response-to>;

      $!socket.close;
    }

    else {
      $!monitor-result = Nil;
    }

    return $!monitor-result;
  }

  #-----------------------------------------------------------------------------
  # Read number of bytes from server. When no/not enaugh bytes an error
  # is thrown.
  #
  method !get-bytes ( int $n --> Buf ) {

    my Buf $bytes = $!socket.receive($n);
    if $bytes.elems == 0 {

      # No data, try again
      #
      $bytes = $!socket.receive($n);
      fatal-message("No response from server") if $bytes.elems == 0;
    }

    if 0 < $bytes.elems < $n {

      # Not 0 but too little, try to get the rest of it
      #
      $bytes.push($!socket.receive($n - $bytes.elems));
      fatal-message("Response corrupted") if $bytes.elems < $n;
    }

    $bytes;
  }
}
