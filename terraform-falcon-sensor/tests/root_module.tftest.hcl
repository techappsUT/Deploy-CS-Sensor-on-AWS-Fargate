# =============================================================================
# Root Module Validation Tests
# Run with: terraform test
# =============================================================================

mock_provider "aws" {}
mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "null" {}
mock_provider "local" {}

# Test: falcon_client_id must be at least 20 characters
run "reject_short_client_id" {
  command = plan

  variables {
    falcon_client_id     = "short"
    falcon_client_secret = "abcdefghijklmnopqrstuvwxyz"
    falcon_cid           = "ABCDEF123456-AB"
    deployment_type      = "eks"
  }

  expect_failures = [
    var.falcon_client_id,
  ]
}

# Test: falcon_client_secret must be at least 20 characters
run "reject_short_client_secret" {
  command = plan

  variables {
    falcon_client_id     = "abcdefghijklmnopqrstuvwxyz"
    falcon_client_secret = "short"
    falcon_cid           = "ABCDEF123456-AB"
    deployment_type      = "eks"
  }

  expect_failures = [
    var.falcon_client_secret,
  ]
}

# Test: falcon_cid must match expected format
run "reject_invalid_cid_format" {
  command = plan

  variables {
    falcon_client_id     = "abcdefghijklmnopqrstuvwxyz"
    falcon_client_secret = "abcdefghijklmnopqrstuvwxyz"
    falcon_cid           = "invalid-format-with-dashes"
    deployment_type      = "eks"
  }

  expect_failures = [
    var.falcon_cid,
  ]
}

# Test: deployment_type must be one of ecs, eks, both
run "reject_invalid_deployment_type" {
  command = plan

  variables {
    falcon_client_id     = "abcdefghijklmnopqrstuvwxyz"
    falcon_client_secret = "abcdefghijklmnopqrstuvwxyz"
    falcon_cid           = "ABCDEF123456-AB"
    deployment_type      = "lambda"
  }

  expect_failures = [
    var.deployment_type,
  ]
}

# Test: ecr_image_tag_mutability must be MUTABLE or IMMUTABLE
run "reject_invalid_tag_mutability" {
  command = plan

  variables {
    falcon_client_id         = "abcdefghijklmnopqrstuvwxyz"
    falcon_client_secret     = "abcdefghijklmnopqrstuvwxyz"
    falcon_cid               = "ABCDEF123456-AB"
    deployment_type          = "eks"
    ecr_image_tag_mutability = "INVALID"
  }

  expect_failures = [
    var.ecr_image_tag_mutability,
  ]
}
