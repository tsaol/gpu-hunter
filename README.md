# grab-gpu

Keep trying to reserve **On-Demand GPU capacity** on AWS until you get it.

When a GPU type is hard to get, `run-instances` fails with
`InsufficientInstanceCapacity`. `grab-gpu.sh` keeps asking for an
**On-Demand Capacity Reservation (ODCR)** across instance types and AZs, and
keeps every reservation it wins. Once you hold the reservation, you can start,
stop and replace instances in it without losing the capacity.

[中文说明](README_CN.md)

## Why ODCR and not run-instances?

| | run-instances | ODCR |
|---|---|---|
| What you get | a running instance | capacity for a type in one AZ, held for you |
| Needs AMI / subnet / SG / key | yes, on every try | no, only type + AZ + count |
| After stop / terminate | capacity goes back to the pool | capacity stays yours |
| Partial result | MinCount lets you take fewer | all or nothing per request (the script halves and retries) |
| Price | On-Demand, while running | On-Demand, **from the moment it is active, used or not** |
| Savings Plans | yes | yes |

## What the script does

- Tries each instance type (in your order) in each AZ where AWS offers it.
- Asks for all remaining instances; on `InsufficientInstanceCapacity` it halves
  the count (4 → 2 → 1) so you keep whatever is free.
- Tags every reservation (`grab-gpu=<tag>`), so `--status` and `--release` can find them.
- Waits longer after each empty round (30 s → max 300 s, with jitter), and resets after a win.
- Stops at once on quota, permission or parameter errors (retrying won't help).
- Optional SNS message on every win and at the end.

## Quick start

Needs bash 4+ and AWS CLI v2. No Python.

```bash
# test first: --dry-run checks permissions and parameters, creates nothing
./grab-gpu.sh -r eu-central-1 -t g6e.12xlarge -n 2 --dry-run

# grab 4 instances, g6e.12xlarge first, then g6e.24xlarge, SNS on success
./grab-gpu.sh -r eu-central-1 -t g6e.12xlarge,g6e.24xlarge -n 4 \
  -s arn:aws:sns:<region>:<account>:<topic>

# keep it running after you log out
nohup ./grab-gpu.sh -r eu-central-1 -t p4d.24xlarge -n 2 > grab.out 2>&1 &

./grab-gpu.sh -r eu-central-1 --status    # what we hold
./grab-gpu.sh -r eu-central-1 --release   # cancel them all, billing stops
```

| Option | Meaning | Default |
|---|---|---|
| `-t, --types` | instance types, comma separated, in priority order | required |
| `-n, --count` | how many instances in total | 1 |
| `-r, --region` | region | `$GRAB_REGION` or eu-central-1 |
| `-z, --azs` | only these AZs | all AZs that offer the type |
| `-m, --min-chunk` | smallest reservation to accept | 1 |
| `-i, --interval` / `--max-interval` | wait between rounds (s) | 30 / 300 |
| `--max-hours` | give up after N hours (exit 4) | 0 = never |
| `-s, --sns` | SNS topic ARN for messages | none |
| `--targeted` | only instances that name the reservation can use it | open |
| `--tag` | tag value, to run several jobs side by side | grab-gpu |
| `--dry-run` | check only | off |

Exit codes: `0` done, `2` no usable type/AZ, `3` fatal error (quota, permission), `4` time limit.

## Using the capacity

With the default `open` match, any instance in the same account with the same
type, platform and AZ uses the reservation automatically. With `--targeted`, pass
`--capacity-reservation-specification CapacityReservationTarget={CapacityReservationId=cr-...}`
to `run-instances`.

## Before you start

1. **Check the On-Demand vCPU quota** (`Running On-Demand G and VT instances`,
   `Running On-Demand P instances`). Often the real problem is the quota, not capacity.
   One p4d.24xlarge is 96 vCPUs.
2. **Give more types and AZs** if the workload allows it. More choices, more chances.
3. **Release what you don't use.** An active ODCR is billed even with no instance in it.
4. For large or long-term needs, also talk to your AWS account team. The script
   only catches capacity that frees up.

## IAM permissions

`ec2:CreateCapacityReservation`, `ec2:DescribeCapacityReservations`,
`ec2:CancelCapacityReservation`, `ec2:DescribeInstanceTypeOfferings`,
`ec2:CreateTags`, and `sns:Publish` if you use `-s`.

## Tests

```bash
tests/test.sh            # offline, a fake aws CLI simulates capacity and quota errors
LIVE=1 tests/test.sh     # also a real --dry-run call (needs credentials, creates nothing)
```

## License

MIT-0. See [LICENSE](LICENSE).
