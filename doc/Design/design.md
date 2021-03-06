```plantuml
title Select a server

state "Server processing" as SProc {

  [*] --> Build : Uri
  Build --> [*] : Client Object
  Build : init object and start\nbackground proc

  [*] --> Select
  Select --> Await
  Await : wait for server select\nto have at least a\nmaster server
  Await --> Select : server
  Select --> [*] : server object
  Select : find proper server

  Receive : receive server\nobjects from channel
  Receive --> Await

  --

  [*] --> Discover : server from uri
  Discover : loop through\nlist of servers
  Discover --> Catagorize : list of servers

  Catagorize : catagorize list\nof servers
  Catagorize --> Send : list of servers
  Catagorize --> Topology : list of servers
  Catagorize --> Interrogate : master server

  Interrogate : ask server for secondary hosts
  Interrogate --> Discover : found servers

  Send : send each server\nobject through channel

  Topology : set server types and\nClient topology
  Topology --> Discover

}
```
