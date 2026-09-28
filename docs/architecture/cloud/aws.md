# AWS Implementation Notes

Status: **Phase 1 — Proposed**

Provider-specific detail for the AWS roles: `aws_ec2`, `aws_image`, and the mapping from
canonical platform concepts to AWS resources.

Abstraction: [../provider-abstraction.md](../provider-abstraction.md).

---

## 1. Resource Mapping

| Canonical | AWS resource | Notes |
|---|---|---|
| Instance | `ec2:RunInstances` | |
| Name | The `Name` tag, **not** an API field | EC2 has no instance name; the tag is the name, which is why the tag lookup in `create_or_adopt` is the name lookup in practice |
| Identifier | The instance ID | Never derived; recorded at create |
| Region | `Placement.AvailabilityZone` | Immutable |
| Zone | The AZ part of the AZ string | |
| Size | `InstanceType` | |
| Network | VPC + subnet, by ID | Symbolic ref resolved at apply time |
| ENI | `networkInterfaces` in the run spec | One primary, plus one per data disk's SGP attachment |
| Security group | `SecurityGroupIds` | Referenced, never created by the build |
| Public IP | `AssociatePublicIpAddress` | **False by default** |
| Key pair | **None** | No key-based access. See §6 |
| Root volume | The instance store or an EBS volume | Explicitly requested, not implicit |
| Data volumes | EBS volumes attached by device name | |
| Image | An AMI ID, resolved from a **region-specific** catalogue entry | See §4 |
| KMS key | `KmsKeyId` | |
| IAM instance profile | `IamInstanceProfile` | Only when the role needs one |
| Tags | EC2 tags (128/256 chars, case-sensitive) | |

**Tags are the only name an EC2 instance has.** This makes EC2 the easiest provider for the
platform's tag-based ownership model: `create_or_adopt` is a
`DescribeInstances` filtered on the `sba_instance_id` tag, and there is no separate name field
that could drift from the tag.

---

## 2. Placement and Naming

| Decision | Value | Rationale |
|---|---|---|
| AZ | The catalogue's `availability_zone`, or resolved from `subnet` | An EC2 instance is pinned to an AZ; a subnet exists in exactly one |
| Catalogued as | `region` + `availability_zone` separately | A user selecting "eu-west-1" is not choosing a zone, and a build that silently picked one would be non-deterministic |
| Name tag | `Name: <short_name>` | The `Name` tag is what the console shows, so the platform sets it to the same short name the guest uses |
| Public IPv4 | **Not assigned** | A public address on a production server is a finding in most baselines. Ingress through the transit gateway or a NAT |
| IPv6 | Opt-in per catalogue | |

An EC2 instance cannot be moved between AZs, so `availability_zone` is effectively immutable
once the instance exists, and it is derived from the subnet. A catalogue entry that names a
region but not a zone leaves the platform to read the zone from the subnet, and that is the
correct default: it makes the subnet the single source of truth for placement.

---

## 3. Capabilities Declaration

```yaml
sba_provider_capabilities:
  name: aws
  zones: true
  spot_instances: true
  max_metadata_key_length: 128        # <-- lower than Azure (512)
  max_metadata_value_length: 256
  max_metadata_count: 50
  metadata_case_sensitive: true
  metadata_allows_uppercase: true
  metadata_allows_special_chars: true # tags allow + = . _ : / @ -  (AZ-1)
  immutable_after_create:
    - account
    - region
    - availability_zone
    - subnet          # an ENI's subnet cannot be changed
    - image           # an AMI change is a rebuild
    - vpc
  resize_without_reboot: [instance_type]
  resize_requires_deallocate: []
  encryption_key_rotatable: true      # through a re-encrypted volume modify
  delete_is_asynchronous: false       # terminate is effectively immediate
  delete_reports_not_found_as: api_error_requiring_normalisation
  max_boot_wait_seconds: 3600
```

**The 128-character tag key limit is the binding AWS constraint**, and it is the reason the
canonical key set is short. `sba_correlation_id` is 21 characters, which fits, but a canonical key
named `sba_run_correlation_identifier` would not — and the TagMapper validates against this
declaration at resolution, so the failure happens before any infrastructure exists.

`delete_reports_not_found_as: api_error_requiring_normalisation` is worth the explicit note: EC2
`terminate-instances` returns `InvalidInstanceID.NotFound` for an instance that has already
terminated, and for one that never existed. A destroy must treat that as success, or a retried
destroy fails forever on a resource it already removed.

---

## 4. Image Strategy

**AMIs are region-specific.** A single catalogue entry cannot hold one AMI ID for three regions.
The catalogue is therefore structured with a per-region reference map.

```yaml
# configuration/images/amazon-linux.yml
- id: al-2025-standard
  provider: aws
  product: Amazon Linux 2025
  os_family: linux
  expires_at: 2028-06-30
  reference:
    eu-west-1:      "ami-0a1b2c3d4e5f6a7b8"
    eu-west-2:      "ami-1f2e3d4c5b6a7988"
    us-east-1:      "ami-2e3d4c5b6a798807"
    ap-southeast-1: "ami-3f4e5d6c7b8a9012"
  owner: amazon
  build_date: "2025-08-14"
```

| Rule | Reason |
|---|---|
| The AMI ID is pinned, never `latest` | Reproducibility, and so a no-op re-run does not trip `OS_VERSION_MISMATCH` |
| The catalogue entry lists every supported region | A missing region is a `RESOLUTION` failure, before any resource exists |
| The AMI's `OwnerId` is validated | An unowned or third-party AMI in a catalogue is a supply-chain risk. [AD-07](../architectural-decisions.md#ad-07-image-catalogue-with-pinning-and-expiry) |
| The image is verified as HVM + EBS-backed | An instance-store-backed AMI cannot use the volume configuration the catalogue specifies |
| SSM parameters are resolved at apply time for SSM-managed instances | Not for a catalogue-driven build. The platform pins IDs so the image is auditable |

SSM Public Parameters would be the AWS-native way to say "the latest approved AMI", and the
platform deliberately does not use them for catalogue-driven builds: an SSM parameter can be
changed by anyone with `ssm:GetParameter`, which would let an image change without a review and
without an `expires_at` check. The catalogue is the approval record.

---

## 5. Instance Profile and IAM

| Use | Mechanism | Identity |
|---|---|---|
| Platform → AWS | OIDC federation, role assumption | `svc-sba-sba-dev`, `-nonprod`, `-prod` |
| Per-run scoping | `aws:PrincipalTag` / session tag conditions | See §7 |
| VM → AWS (SSM, S3) | An instance profile attached at launch | `sba-payments-prod-node` |
| SSM activation | An activation ID issued by the platform for a bounded window | One activation per build window |

The instance profile is a catalogue reference, not something the build creates. Creating an
instance profile means creating a role, a policy, and possibly a boundary — three security
artefacts that belong in their own change process, and that a build could get subtly wrong in
ways that are not obvious to review.

**SSM instead of SSH keys.** SSM Session Manager means no key material, no inbound port, and a
fully auditable session log. The `install_agents` stage installs the SSM agent and requests an
activation; the platform never handles an SSH private key for a server it created.

---

## 6. Authentication and Key Management

| Concern | AWS's model | The platform's rule |
|---|---|---|
| Bootstrap access | The key pair, or a password on the AMI | **Neither.** SSM only, from the start |
| Windows administrator | The AMI's baked-in password, which is a known published value | The build rotates it from the credential store immediately, with `no_log`, and this is the one moment an AWS password enters the flow |
| Linux access | Key pair at launch | No key pair. SSM |
| Key rotation | Not applicable | n/a |
| Root/Administrator disabling | Manual | `os_config` disables it after the local administrator is set up |

**There is no key pair, and no inbound SSH or RDP.** This is the cleanest of the three
providers' security positions, and the platform does not weaken it by adding a key pair for
convenience. The one unavoidable credential is the Windows administrator password baked into the
AMI, and the catalogue therefore prefers an image that has already randomised it.

---

## 7. Per-Run Least Privilege

| Mechanism | How | Note |
|---|---|---|
| `aws:PrincipalTag` | The platform sets a session tag on the assumed role | Does **not** support resource constraints by tag. Useful for CloudTrail attribution, not for restricting which resources can be touched |
| Resource tag conditions | `aws:ResourceTag/${TagKey}` in the policy | Works on EC2 and EBS, and is the mechanism to use |
| SCP on the account | Deny `ec2:RunInstances`/`TerminateInstances` outside the platform's roles | The outer boundary; cannot express "which run" |
| A per-run boundary | Not needed; the tag condition is sufficient | |

**The limitation to state plainly:** `aws:PrincipalTag` cannot be used in a resource-based
condition. So "this role may only touch resources tagged with this `sba_instance_id`" is expressed
with `aws:ResourceTag/sba_instance_id`, which requires the platform to know the instance ID
before the call — which it does, because the ID is assigned by ServiceNow before anything exists.
That is a direct benefit of `AD-05` and a good illustration of why generating the key early
simplifies more than it costs.

| Action | Prod condition |
|---|---|
| `CreateTags` | Allowed, so the key can be applied atomically |
| `RunInstances` | Allowed |
| `CreateVolume`, `AttachVolume` | Allowed |
| `TerminateInstances` | Denied unless the tag matches |
| `ModifyInstanceAttribute` | Denied unless the tag matches |
| `DeleteTags` | **Denied always.** Removing `sba_instance_id` destroys the ownership proof ([idempotency.md §11 ](../idempotency.md#11-known-limitations)) |
| `ModifyImageAttribute` | Denied always |
| `RunInstances` with a user data override | Denied. User data is a build input, not an ad-hoc override |

The `DeleteTags` denial is the one that is easy to overlook and expensive to get wrong. An
identity allowed to delete tags can make a resource invisible to the platform, and the platform's
entire ownership model depends on that tag. Denying it is cheap; recovering from its removal
requires the daily orphan sweep.

---

## 8. Stage Implementation Notes

### 8.1 `provision`

```yaml
# 1. lookup by tag. DescribeInstances is the only read used for ownership.
- amazon.aws.ec2_instance_info:
    filters:
      - "tag:sba_instance_id={{ sba_instance_id }}"
      - "instance-state-name=pending"
      - "instance-state-name=running"
      - "instance-state-name=stopping"
      - "instance-state-name=stopped"
  register: sba_existing

# 2. absent -> create. Present -> adopt and converge.
#    The amazon.aws.ec2_instance module is create-or-update, so one task path serves both.
- amazon.aws.ec2_instance:
    name: "{{ sba_name }}"                       # becomes the Name tag
    image_id: "{{ sba_image_id }}"               # from the region map
    instance_type: "{{ sba_size }}"
    vpc_subnet_id: "{{ sba_subnet_id }}"         # carries the AZ
    instance_profile: "{{ sba_instance_profile | default(omit) }}"
    network_type: "{{ sba_network_type | default('default') }}"
    ebs_optimized: true
    instance_tags: "{{ sba_tags }}"              # sba_instance_id in the same call
    root_volume_size_gb: "{{ sba_root_volume_size_gb }}"
    root_volume_type: gp3
    root_volume_encryption: true
    kms_key_id: "{{ sba_encryption_key_id | default(omit) }}"
    network_ids: [ "{{ security_group_ids | join(',') }}" ]
    state: running
    wait: true
    wait_timeout: 900
  no_log: true
```

Two AWS specifics that this depends on:

**Tag filters are eventual.** `DescribeInstances` filtered on a tag may not return an instance
whose tag was written moments earlier, because EC2 tag propagation through the API is not
immediate. This is the
[limitation 5](../idempotency.md#11-known-limitations) in the idempotency design: on an ambiguous
create, the platform **retries the read** with a bounded backoff before writing, and if the read
is still empty it raises `PROVIDER_EVENTUAL_CONSISTENCY` rather than creating a second instance.
Creating on a stale read is exactly the duplication `AD-05` exists to prevent, and the correct
trade is to fail and let a human retry rather than risk two servers.

**`instance_tags` is applied in the create call.** A separate `CreateTags` afterwards would leave
the ownership gap described in
[idempotency.md §4.3 ](../idempotency.md#43-the-tag-with-create-rule).

### 8.2 `wait_for_ready`

`wait: true` on the create covers `instance-state-name=running`, which on EC2 means the
hypervisor has started the guest, not that the guest OS is usable. As with Azure, provider
readiness is necessary and not sufficient: SSM agent registration in `install_agents` is what
actually proves the server is usable, and it is what raises `AGENT_NOT_REPORTING`.

### 8.3 `converge_instance`

| Change | Mechanism | Impact |
|---|---|---|
| Resize | `ModifyInstanceType` | In place for compatible families. A family change requires a stop/start |
| Volume expand | `ModifyVolume` | Online, no reboot. **Grow only** |
| Volume type change | `ModifyVolume` | `gp2` → `gp3` in place. Across families it needs a new volume and a data migration |
| Retag | `CreateTags` on the instance | None |
| Key rotation | Snapshot → re-encrypt → restore → swap | **Not a converge.** A change with a data-copy step |
| Move between subnets | Not possible | Immutable |

The key-rotation row is the interesting one. AWS can rotate a customer-managed key in place *if*
the volume is already encrypted with that key, but moving an existing volume to a new key
requires a snapshot and a re-encrypt. The platform classifies that as a change requiring a
ServiceNow request, and never as a converge, because it involves a data copy and a point-in-time
risk.

### 8.4 `decommission`

```
  1. terminate the instance     (TerminateInstances; wait: true)
  2. delete the ENIs            (after the instance detaches them)
  3. delete the data volumes    (after the instance detaches them)
  4. delete the security-group associations (done by detach)
  5. delete the DNS record set
  6. delete the ServiceNow CI record
  7. remove the AD computer object (only if the run created it)
```

EC2 detach-then-delete ordering is mandatory: a volume or ENI attached to an instance cannot be
deleted, and attempting it returns `VolumeInUse`. The instance termination is asynchronous from
the API's perspective even with `wait: true`, so step 2 and 3 need their own bounded wait before
they will succeed, and a retry with backoff is the right mechanism rather than a fixed sleep.

**A terminating instance still has its tags and still appears in a `DescribeInstances` filtered
on `sba_instance_id`.** A destroy that re-runs during the termination window therefore finds the
instance, sees it as `shutting-down`, and must treat that as success-in-progress rather than as
"an instance exists, delete it again".

---

## 9. Error Mapping

| AWS error | Platform code | Retryable |
|---|---|:--:|
| `RequestLimitExceeded`, `Throttling` | `CLOUD_API_THROTTLED` | yes |
| `RequestExpired`, socket timeout | `CLOUD_API_TIMEOUT` | yes |
| `InvalidInstanceID.NotFound` on delete | Normalised to success | n/a |
| `InvalidAMIID.NotFound`, `InvalidAMIID.Malformed` | `IMAGE_NOT_FOUND` | no |
| `InvalidParameterValue` | `CLOUD_API_REJECTED` | no |
| `UnauthorizedOperation`, `AccessDenied` | `AUTHZ_DENIED` | no |
| `InsufficientInstanceCapacity` | `ZONE_CAPACITY_EXHAUSTED` | no |
| `VcpuLimitExceeded` | `QUOTA_EXCEEDED` | no |
| `InsufficientFreeAddressesInSubnet` | `SUBNET_IP_EXHAUSTED` | no |
| `InvalidVolumeType` | `SIZE_NOT_AVAILABLE_IN_REGION` | no |
| `OptInRequired`, key not enabled | `PROVIDER_FEATURE_NOT_ENABLED` | no |
| `DependencyViolation` on a volume delete | A bounded retry | yes |

`DependencyViolation` is the one that looks like a permanent failure and is not: it means the
volume is still attached because the instance termination is still in progress, and it resolves
itself within a minute. Classifying it as terminal would make every destroy of a recent instance
fail.

---

## 10. Naming and Tagging

| Limit | Value | Binding? |
|---|---|---|
| Tag key | 128 | **Yes** for verbose canonical keys |
| Tag value | 256 | No |
| Tag count | 50 | Only if verbose |
| `Name` tag value | 256 | No |
| Instance ID | 19 | No |
| Key pair name | 255 | Not used |
| AMI ID | `ami-` + 17 | No |

```yaml
sba_tags:
  Name: "{{ sba_name }}"                 # the conventional console name
  sba_instance_id: "{{ sba_instance_id }}"
  sba_application: "{{ sba_application }}"
  sba_environment: "{{ sba_environment }}"
  sba_request_id: "{{ sba_request_id }}"
  sba_change_ref: "{{ sba_change_reference }}"
  sba_git_sha: "{{ sba_git_sha }}"
  sba_correlation_id: "{{ sba_correlation_id }}"
  sba_managed_by: sba
  sba_run_id: "{{ sba_run_id }}"
  owner: "{{ sba_owner }}"
  cost_center: "{{ sba_cost_center }}"
  data_classification: "{{ sba_data_classification }}"
```

The character set is the widest of the three (`+ = . _ : / @ -`), so a cost centre like
`FIN/1234` is fine on AWS and **fails on Azure**, which does not allow `/`. The TagMapper
validates against the active provider's declared character set, so this is caught at resolution
for the Azure run rather than at apply time — and, more usefully, it is visible in the golden
resolution files during review, where a cost-centre format change is far more likely to be
spotted than in an apply log.

---

## 11. Security Checklist

| Check | Mechanism |
|---|---|
| No key pair | Enforced by the role; no `key_name` parameter exists |
| No public IP | The default; the role has no `associate_public_ip_address: true` path without a policy exception |
| EBS encryption | Required, with a CMK where the policy demands one |
| IMDSv2 required | `HttpTokens=required` on every ENI |
| No IMDS hop limit > 1 | Prevents a container on the host reaching the instance metadata |
| SSM instead of SSH/RDP | No inbound ports in any security group the platform references |
| Session Manager logging | CloudTrail plus Session Manager logs retained per policy |
| EBS snapshot encryption | Default on, and a scheduled scan for unencrypted volumes |
| AWS Config | Enabled, with the rules for encryption, IMDSv2, and public access |
| SCP | Denies `ec2:RunInstances` for identities outside the platform roles |
| `DeleteTags` denied for the platform's run identity | The ownership-proof rule from §7 |
| GuardDuty | Enabled, with findings routed to the security team |

**IMDSv2 required with a hop limit of 1** deserves a note. IMDS is how an EC2 instance gets its
own role credentials, and the classic SSRF-to-credential-theft attack is exactly the
un-necessary-hop-limit case: a workload on the instance that can make a request to
`169.254.169.254` gets credentials it should not have. `HttpPutResponseHopLimit: 1` plus
`HttpTokens: required` closes it, and both are settings the platform sets on every ENI it
creates.

---

## 12. Next

- [provider-abstraction.md](../provider-abstraction.md) — the contract this implements
- [azure.md](azure.md), [gcp.md](gcp.md) — the peers
- [../../security/security-architecture.md](../../security/security-architecture.md) — IAM and R-08
- [../idempotency.md](../idempotency.md) — create-or-adopt and the tag-with-create rule
