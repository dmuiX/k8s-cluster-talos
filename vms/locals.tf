locals {
  all_nodes = yamldecode(file(var.nodes_file_path))["nodes"]
}
