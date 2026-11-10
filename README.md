# gpu-hunter

> [!WARNING]
> **For demonstration and learning only. Do not use in production.**
> This is sample code, not an official AWS tool. It has not been tested at
> production scale, has no production-grade error handling, monitoring or audit,
> and comes with no warranty (see [LICENSE](LICENSE)). Capacity Reservations
> **cost money from the moment they exist**, used or not. You are responsible for
> any reservations it creates and for releasing them. Read the code before you run it.

A bash script that keeps requesting an **On-Demand Capacity Reservation (ODCR)**
for GPU instance types across Availability Zones, until it reaches a target
instance count or you stop it. It does not guarantee capacity: it only automates
the retry advice from the AWS documentation (retry later, try another AZ, request
fewer instances, try another instance type).

[中文说明](README_CN.md) · [How the mechanism works (中文)](docs/MECHANISM.md)

## Why ODCR and not run-instances

| | run-instances | ODCR (immediate) |
|---|---|---|
| What you get | a running instance | capacity for one instance type + platform + tenancy in one AZ |
| Needs AMI / subnet / security group | yes, on every try | no |
| After the instance is stopped / terminated | capacity goes back | the reservation stays until you cancel it |
| Partial result | `MinCount` lets you take fewer | one request = one reservation of exactly the requested count |
| Price | On-Demand, while the instance runs | On-Demand, **while the reservation exists, used or not** (per second, 60 s minimum) |
| Savings Plans / Regional RI discounts | apply | apply (zonal RI discounts do not) |

Source: [EC2 Capacity Reservations](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-capacity-reservations.html),
[pricing and billing](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/capacity-reservations-pricing-billing.html).

### Consider the native option first

[Capacity Reservation Fleets](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/cr-fleets.html)
are managed by AWS: if capacity is short, the fleet keeps trying in the
background until it reaches the target, and it replaces reservations that get
cancelled. A fleet works in **one AZ only** and supports **`open` matching only**.
Use this script when you need several AZs in one run, `targeted` matching, or a
per-attempt log. See [docs/MECHANISM.md §4](docs/MECHANISM.md).

## What the script does

1. Lists which AZs offer each instance type (`describe-instance-type-offerings`)
   and skips the rest.
2. Checks that it can read Capacity Reservations; stops if not.
3. Each round, for each type (your order) and each AZ, requests all remaining
   instances. On `InsufficientInstanceCapacity` it halves the count (4 → 2 → 1,
   never below `--min-chunk` except for the last few).
4. A reservation returned as `active` or `pending` counts as won (state can stay
   `pending` for up to ~5 minutes due to eventual consistency; the script never
   cancels it). One returned as `failed` does not count. Pending ones are checked
   again; if one turns `failed`, its count goes back and the hunt continues.
   Before it reports DONE it waits up to 6 minutes for pending ones to settle.
5. Calls the CLI with `AWS_MAX_ATTEMPTS=1` (no hidden retries) and a unique
   `ClientToken` per request. On an unclear result (network error, 5xx) it
   re-sends the **same** request up to 2 times, so a lost response can't create a
   second reservation. If it is still unclear, it sends nothing new in that round.
6. Each round it re-reads from AWS how many instances this run holds
   (tag `gpu-hunter-run`). It only ever lowers the remaining count from that
   number, never raises it, because describe calls are eventually consistent.
7. Between rounds: wait ×1.5 per empty round, from `--interval` (30 s) up to
   `--max-interval` (300 s), plus jitter. On API throttling it stops the round at
   once and waits the maximum.
8. Stops at once on quota, permission or parameter errors.
9. Writes one CSV line per attempt and a summary line at exit.

## Requirements

- bash 4+, AWS CLI v2, credentials for the target account and Region.
- On-Demand vCPU quota for the instance family (reservations count against it).
- IAM: `ec2:CreateCapacityReservation`, `ec2:DescribeCapacityReservations`,
  `ec2:CancelCapacityReservation`, `ec2:DescribeInstanceTypeOfferings`,
  `ec2:CreateTags`; `sns:Publish` if you use `-s`.

## Usage

```bash
# 1. always start with a dry run: checks permissions and parameters, creates nothing
./gpu-hunter.sh -r eu-central-1 -t g6e.12xlarge -n 2 --dry-run

# 2. reserve 4 instances: g6e.12xlarge first, then g6e.24xlarge; give up after 6 hours
./gpu-hunter.sh -r eu-central-1 -t g6e.12xlarge,g6e.24xlarge -n 4 --max-hours 6

# 3. see what this tool holds, and release it (billing stops)
./gpu-hunter.sh -r eu-central-1 --status
./gpu-hunter.sh -r eu-central-1 --release

# 4. summarise a run (default: the newest events file in this folder)
tools/report.sh
```

| Option | Meaning | Default |
|---|---|---|
| `-t, --types` | instance types, comma separated, in priority order | required |
| `-n, --count` | total instances wanted | 1 |
| `-r, --region` | Region | `$GPU_HUNTER_REGION`, else eu-central-1 |
| `-z, --azs` | only these AZs (names, as seen in your account) | every AZ that offers the type |
| `-m, --min-chunk` | smallest reservation to request | 1 |
| `-i, --interval` / `--max-interval` | wait between rounds, seconds | 30 / 300 |
| `--max-hours` | stop after N hours (exit 4) | 0 = no limit |
| `-s, --sns` | SNS topic ARN for messages | none |
| `--targeted` | only instances that name the reservation can use it | `open` |
| `--platform` | must match the AMI's `PlatformDetails` | `Linux/UNIX` |
| `--tag` | value of the `gpu-hunter` tag, to keep jobs apart | `gpu-hunter` |
| `--dry-run` | check only | off |

Exit codes: `0` target reached · `1` bad input · `2` no usable type/AZ ·
`3` fatal (quota, permission, parameters) · `4` time limit · `130` stopped by signal.
Reservations already won are **kept** on every exit; release them with `--release`.

Environment: `GPU_HUNTER_REGION`, `GPU_HUNTER_LOG` (default `./gpu-hunter.log`),
`GPU_HUNTER_EVENTS` (default `./gpu-hunter-events-<run id>.csv`, one file per run).

## Things to know before you run it

- **`open` matching takes running instances.** If the account already runs
  instances of the same type, platform and AZ, they move into the new reservation
  as soon as it is active. Use `--targeted` to avoid this, then launch with
  `--capacity-reservation-specification CapacityReservationTarget={CapacityReservationId=cr-...}`.
- **The API rate limit is shared.** `CreateCapacityReservation` is a mutating
  action; EC2 throttles mutating actions per account and Region with one shared
  bucket (50 tokens, refill 5/s at the time of writing). Very short intervals can
  throttle the customer's own automation. See
  [EC2 API throttling](https://docs.aws.amazon.com/ec2/latest/devguide/ec2-api-throttling.html).
- **Every no-capacity attempt leaves a `failed` reservation record.** It costs
  nothing, does not count against quota, and disappears from view after 60 minutes.
- **Run it in the same Region** if you can (for example CloudShell or a small
  instance there): in our test, a describe call took ~0.4 s in-Region and ~1.3 s
  cross-Region (create calls were only measured cross-Region, ~1.3–1.5 s).
- AZ names map to different physical AZs in each account. Across accounts, use AZ IDs.
- The script does not watch reservations after it exits.

## How to judge whether it works

See [docs/MECHANISM.md §7](docs/MECHANISM.md): time to first / full
reservation, fill rate, attempts per win, win rate per type × AZ, throttle
count, and idle cost (CloudWatch `InstanceUtilization`). Compare against a
baseline in alternating time windows, never two configurations at the same time
in the same account.

## Tests

```bash
tests/test.sh          # offline: a stateful fake aws CLI simulates no-capacity,
                       # failed / pending states, lost responses, quota, permission, bad input
LIVE=1 tests/test.sh   # also one real --dry-run call (needs credentials, creates nothing)
                       # takes about 30 s (some tests wait on purpose)
```

What has and has not been verified is listed in [docs/MECHANISM.md §7.4](docs/MECHANISM.md).

## License

MIT-0. See [LICENSE](LICENSE). Provided "as is", without warranty of any kind.
