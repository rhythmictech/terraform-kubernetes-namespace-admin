
########################################
# Namespace
# the kubernetes namespace
########################################
resource "kubernetes_namespace" "this" {
  metadata {
    name        = var.namespace
    labels      = local.labels
    annotations = {}
  }
}

########################################
# Create the Private Key
########################################
resource "tls_private_key" "client_key" {
  count     = length(var.namespace_admins)
  algorithm = "RSA"
  rsa_bits  = 4096
}

########################################
# Create CSR
# to request a certificate from our Kubernetes' CA
########################################
resource "tls_cert_request" "client_csr" {
  count           = length(var.namespace_admins)
  key_algorithm   = "RSA"
  private_key_pem = tls_private_key.client_key[count.index].private_key_pem

  subject {
    common_name  = var.namespace_admins[count.index]
    organization = var.namespace
  }
}

########################################
# Write out request file and
# Request K8s to sign our keys
########################################
resource "local_file" "csr_requests" {
  count    = length(var.namespace_admins)
  filename = join("", [local.csr_request_template_path, "${var.namespace_admins[count.index]}.yaml"])

  content = templatefile(
    "${path.module}/certificate_signing_request.yaml.tpl", {
      name       = var.namespace_admins[count.index],
      namespace  = var.namespace,
      base64_csr = base64encode(tls_cert_request.client_csr[count.index].cert_request_pem)
  })

  provisioner "local-exec" {
    command = <<EOT
kubectl --kubeconfig ./${var.kubeconfig_file_name} \
  create -f ${path.module}${var.namespace_admins[count.index]}.yaml

kubectl --kubeconfig ./${var.kubeconfig_file_name} \
  certificate approve ${var.namespace_admins[count.index]}

kubectl --kubeconfig ./${var.kubeconfig_file_name} \
  get csr ${var.namespace_admins[count.index]} \
  -o jsonpath='{.status.certificate}' \
  | base64 -d > ${var.namespace_admins[count.index]}.pem
EOT
  }
}

data "local_file" "client_crt" {
  count      = length(var.namespace_admins)
  filename   = "${var.namespace_admins[count.index]}.pem"
  depends_on = [local_file.csr_requests]
}

########################################
# Kubeconfig files!
# this resource writes the kubeconfigs to a file
########################################
resource "local_file" "user_kubeconfigs" {
  count    = length(var.namespace_admins)
  filename = "${path.module}/kubeconfigs/${var.namespace_admins[count.index]}.yaml"
  content = templatefile(
    "${path.module}/kubeconfig.yaml.tpl", {
      # CA, CRT, and KEY data need to be base64
      #  but are already encoded
      CA_DATA         = var.cluster_ca_certificate
      API_SERVER      = var.host,
      CLUSTER_NAME    = var.cluster_name,
      namespace       = var.namespace,
      username        = var.namespace_admins[count.index],
      CLIENT_CRT_DATA = base64encode(data.local_file.client_crt[count.index].content),
      CLIENT_KEY_DATA = base64encode(tls_private_key.client_key[count.index].private_key_pem)
  })
}

resource "kubernetes_role" "namespace_admin" {
  metadata {
    name      = local.kubernetes_role_name
    namespace = var.namespace
    labels    = local.labels
  }
  rule {
    api_groups = var.namespace_admins_rule.api_groups
    resources  = var.namespace_admins_rule.resources
    verbs      = var.namespace_admins_rule.verbs
  }
}

resource "kubernetes_role_binding" "namespace_admin" {
  metadata {
    name      = local.kubernetes_role_binding_name
    namespace = var.namespace
    labels    = local.labels
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = local.kubernetes_role_name
  }
  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Group"
    name      = var.namespace
  }
}
