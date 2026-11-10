# gpu-hunter

> [!WARNING]
> **只用于演示和学习，不要用在生产环境。**
> 这是示例代码，不是 AWS 官方工具。没有经过生产规模的测试，也没有生产级别的
> 错误处理、监控和审计，不提供任何保证（见 [LICENSE](LICENSE)）。
> 容量预留**从创建那一刻起就开始收费**，用不用都收。脚本建出来的预留由你负责，
> 也由你负责释放。运行前请先读一遍代码。

一个 bash 脚本：在多个机型、多个 AZ 之间不断申请 **ODCR（按需容量预留）**，
直到抢满目标台数，或者你让它停下来。它**不保证一定能抢到**，只是把 AWS 官方文档里
建议的做法自动化：过一会儿再试、换 AZ、少要一点、换机型。

[English](README.md) · [机制详解](docs/MECHANISM.md)

## 为什么用 ODCR，不直接 run-instances

| | run-instances | ODCR（立即生效） |
|---|---|---|
| 拿到的是什么 | 一台运行中的机器 | 某个 AZ 里，某个机型 + 平台 + 租户类型的容量 |
| 每次都要 AMI / 子网 / 安全组 | 要 | 不要 |
| 机器 stop / terminate 以后 | 容量还回去 | 预留一直在，直到你取消 |
| 只抢到一部分 | 用 `MinCount` 可以少拿 | 一次请求就是一个预留，数量就是请求的数量 |
| 价格 | 按需价，机器运行时才收 | 按需价，**预留存在就收，用不用都收**（按秒计，最少 60 秒） |
| Savings Plans / 区域型 RI 折扣 | 有效 | 有效（可用区型 RI 无效） |

来源：[EC2 Capacity Reservations](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-capacity-reservations.html)、
[计费](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/capacity-reservations-pricing-billing.html)。

### 先考虑官方的方案

[Capacity Reservation Fleet](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/cr-fleets.html)
由 AWS 托管：容量不够时会在后台一直重试，直到满足目标；预留被取消了还会自动补回来。
但它**只能在一个 AZ 里**，**只支持 open 模式**。
需要多个 AZ 一起抢、需要 targeted 模式、或者想要每次尝试的记录时，再用这个脚本。
详见 [docs/MECHANISM.md 第 4 节](docs/MECHANISM.md)。

## 脚本做了什么

1. 查每个机型在哪些 AZ 有，没有的跳过。
2. 检查有没有读取预留的权限，没有就停。
3. 每一轮，按你给的机型顺序、在每个 AZ 里申请剩下的全部数量；碰到 `InsufficientInstanceCapacity` 就减半（4 → 2 → 1，除了最后几台，不会低于 `--min-chunk`）。
4. 返回 `active` 或 `pending` 都算抢到。因为最终一致性，`pending` 最多可能持续约 5 分钟，脚本不会取消它。返回 `failed` 不算。
5. 用 `AWS_MAX_ATTEMPTS=1` 调 CLI（不让 CLI 偷偷重试），每个请求都带一个唯一的 `ClientToken`。碰到网络错误、5xx 这类"不知道成没成功"的情况，就把**同一个**请求再发一次，所以响应丢了也不会多建一个预留。
6. 每轮开始前去 AWS 查这次运行（tag `gpu-hunter-run`）已经拿到了多少台。因为查询是最终一致的，这个数字只用来**调低**剩余数量，不会调高。
7. 轮与轮之间：每次一无所获就把等待时间乘 1.5，从 `--interval`（30 秒）到 `--max-interval`（300 秒），加随机抖动；碰到限流就直接等最长时间。
8. 碰到配额、权限、参数错误马上停。
9. 每次尝试都在 CSV 里记一行，结束时打印一行统计。

## 前提

- bash 4+、AWS CLI v2、目标账号和区域的凭证。
- 这个机型系列的按需 vCPU 配额（预留也算在里面）。
- IAM 权限：`ec2:CreateCapacityReservation`、`ec2:DescribeCapacityReservations`、`ec2:CancelCapacityReservation`、`ec2:DescribeInstanceTypeOfferings`、`ec2:CreateTags`；用 `-s` 的话还要 `sns:Publish`。

## 怎么用

```bash
# 1. 一定先 dry-run：只检查权限和参数，不创建任何东西
./gpu-hunter.sh -r eu-central-1 -t g6e.12xlarge -n 2 --dry-run

# 2. 抢 4 台：先试 g6e.12xlarge，再试 g6e.24xlarge；6 小时还没抢满就停
./gpu-hunter.sh -r eu-central-1 -t g6e.12xlarge,g6e.24xlarge -n 4 --max-hours 6

# 3. 看这个工具建了哪些预留，不用了就释放（停止收费）
./gpu-hunter.sh -r eu-central-1 --status
./gpu-hunter.sh -r eu-central-1 --release

# 4. 汇总一次运行的结果
tools/report.sh gpu-hunter-events-<run id>.csv
```

参数、退出码和环境变量见 [README.md](README.md)。

## 运行前要知道

- **open 模式会吃掉正在跑的实例**：账号里已经有同机型、同平台、同 AZ 的实例的话，预留一生效它们就会占进来。不想这样就用 `--targeted`。
- **API 限流是共用的**：`CreateCapacityReservation` 属于 mutating 操作，EC2 按账号 + 区域给所有 mutating 操作共用一个令牌桶（写这篇时是 50 个令牌，每秒补 5 个）。间隔太短会影响客户自己的自动化。见 [EC2 API throttling](https://docs.aws.amazon.com/ec2/latest/devguide/ec2-api-throttling.html)。
- **每次没抢到都会留下一条 `failed` 记录**：不收费，不占配额，60 分钟后就看不到了。
- **尽量在同一个区域里运行**（比如 CloudShell，或者在那个区域开一台小机器）：我们实测，查询请求在本区域约 0.4 秒、跨区域约 1.3 秒；创建请求只测过跨区域，约 1.3–1.5 秒。
- 同一个 AZ 名字在不同账号里对应的物理 AZ 不一样，跨账号要用 AZ ID。
- 脚本退出以后，就不会再管这些预留了。

## 怎么判断效果

见 [docs/MECHANISM.md 第 7 节](docs/MECHANISM.md)：第一次抢到用时、抢满用时、完成率、每次成功要请求几次、各个机型 × AZ 的成功率、被限流次数、闲置成本（CloudWatch `InstanceUtilization`）。要和基线对比，两种配置轮流跑，**不要在同一个账号里同时跑两种配置**。

## 测试

```bash
tests/test.sh          # 离线测试：用有状态的假 aws 命令模拟没容量、failed / pending 状态、
                       # 响应丢失、配额、没权限、参数错误
LIVE=1 tests/test.sh   # 再加一次真实的 --dry-run（需要凭证，不创建任何东西）
```

哪些验证过、哪些没验证过，见 [docs/MECHANISM.md 第 7.4 节](docs/MECHANISM.md)。

## License

MIT-0，见 [LICENSE](LICENSE)。按"原样"提供，不提供任何形式的保证。
