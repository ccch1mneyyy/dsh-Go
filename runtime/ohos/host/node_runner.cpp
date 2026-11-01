#include <node.h>

#include "publication_binding.h"

// The Ark-side host owns the one-start-per-application guard. Keep this library
// resident until process exit; registration must happen before node::Start.
extern "C" __attribute__((visibility("default")))
int dsh_node_start(int argc, char** argv) {
  RegisterPublicationBinding();
  return node::Start(argc, argv);
}
