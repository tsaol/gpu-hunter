# 按需 GPU 容量预留（ODCR）机制详解

> **声明**：本文和本仓库的代码**只用于演示和学习**，不是 AWS 官方工具，也没有经过生产环境验证。
> **不要直接用在生产环境。** 文中的限制、价格、配额以 AWS 官方文档为准，它们会变化。
> 本文最后核对日期：2026-11-10。

本文回答四个问题：

1. 开不出 GPU（`InsufficientInstanceCapacity`）是怎么回事？
2. ODCR（On-Demand Capacity Reservation，按需容量预留）是怎么工作的？
3. `gpu-hunter.sh` 的每个设计，分别对应哪条机制？
4. 速度怎么样，效果怎么评估？

每条事实后面都标了来源：**[文档]** = AWS 官方文档，**[实测]** = 我们自己调用 API 测出来的，**[推断]** = 根据前两者推出来的，没有直接证据。

---

## 1. 为什么开不出 GPU

- 报 `InsufficientInstanceCapacity`（下面简称 **ICE**），意思是 **AWS 当时在这个 AZ 没有足够的按需容量**。[文档：Troubleshoot launch issues]
- 官方给的办法有四个：**等几分钟再试**（"容量变化很频繁"）、**请求少一点**（比如 15 台拆成 3×5 或 15×1）、**换 AZ**、**换机型**。[文档：Troubleshoot launch issues]
- 还有一种失败不是没货，而是**配额不够**：请求的数量超过了账号的按需实例配额。这种错误重试没用，要去申请提高配额。[文档：Create a Capacity Reservation]

`gpu-hunter.sh` 就是把官方的这四个办法自动化：一直重试、拆小、换 AZ、换机型。

---

## 2. ODCR 是什么

ODCR 在**某一个 AZ** 里，为**某个机型 + 平台 + 租户类型**预留容量。[文档：ODCR 概述]

### 2.1 两种 ODCR

| | 立即生效（本工具只用这种） | 未来日期（future-dated） |
|---|---|---|
| 什么时候生效 | 创建成功就生效 | 提前 5–120 天申请，到日期才生效 |
| 有没有承诺期 | **没有**，随时可以取消，取消免费 | 有：C/G/I/M/R/T 最少 14 天，U/X 最少 12 周 |
| 支持哪些机型 | 所有支持的机型 | **只有 C、G、I、M、R、T、U、X 系列**，**不包括 P 系列** |
| 最小数量 | 1 台 | 合计至少 32 vCPU |
| 取消 | 免费 | 承诺期内取消要付取消费（25%–50%） |

来源：[文档：ODCR 概述、Create、Cancel]

> 对 GPU 来说：G 系列（g5/g6/g6e/g7…）可以用"未来日期"提前约，P 系列（p4d/p5/p5en…）不行。本工具只处理"立即生效"的 ODCR。

### 2.2 哪些实例会用上预留：open 和 targeted

- 实例的**机型、平台、AZ、租户类型**四项都对上，才能用这个预留。[文档]
- **open**（默认）：只要四项对得上，**新开的和已经在跑的**实例都会自动进到预留里。也包括 Auto Scaling、EKS、ECS、Batch 等服务替你开的实例。[文档：ODCR 概述、Create]
- **targeted**：只有开机时明确指定这个预留的实例才能用。[文档]
- ⚠️ 用 open 模式时，如果账号里**已经有**同机型、同 AZ 在跑的实例，预留一生效，这些实例就会立刻占掉它，你"抢到"的容量就被现有的机器用了。要避免这种情况，用 `--targeted`。[文档：Create 页的 Note]
- 平台要和 AMI 的 `PlatformDetails` 一致，比如 `Linux/UNIX` 和 `Red Hat Enterprise Linux` 是两个不同的平台。[文档：Supported platforms]

### 2.3 状态

| 状态 | 意思 |
|---|---|
| `pending` | 请求成功了，容量还在准备 |
| `active` | 可以用了 |
| `failed` | 请求失败了：参数不对、没容量或者超了配额。**失败的记录可以查看 60 分钟** |
| `cancelled` / `expired` | 被取消 / 到期了 |
| `assessing` / `scheduled` / `delayed` / `unsupported` / `cancelling` | 只有"未来日期"的 ODCR 才有这些状态 |

来源：[文档：View the state of a Capacity Reservation]

两个容易踩的坑：

1. **最终一致性**：创建后最多可能要 **5 分钟**，状态才显示 `active`。这段时间显示 `pending`，但**可能已经能用了**。[文档：View the state]
   → 所以 `pending` **不能当成失败**，更不能因为一直 pending 就把它取消掉。
2. **没抢到也会留下记录**：每次 ICE 失败，账号里都会多一条 `failed` 状态的记录，打的 tag 也会带上。[实测] 这些记录**不占配额**（官方列出的占配额状态里没有 `failed`）[文档：Quotas]，60 分钟后就看不到了 [文档]。

### 2.4 计费

- 按**按需价格**收费，**不管有没有实例在用**。没用的部分在账单上显示为 unused reservation。[文档：Pricing and billing]
- 实例用上预留以后，**只收实例的钱**，不会重复收。[文档]
- **按秒计费，最少 60 秒**。[文档]
  → 抢到以后马上取消，也至少收 60 秒的钱。
- **Savings Plans** 和**区域型 Reserved Instances** 的折扣对 ODCR 有效；**可用区型 RI 的折扣无效**。[文档]
- 立即生效的 ODCR 可以随时取消，取消免费。取消以后，正在跑的实例**会继续运行**，按普通按需价收费。[文档：Cancel]

### 2.5 配额和限制

- ODCR 占的是**按需实例配额**（On-Demand vCPU 配额）。能预留的数量 = 配额 − 正在运行的实例。处于 `assessing / scheduled / pending / active / delayed` 状态的预留都算在配额里。[文档：Quotas]
  → 现有机器加上要抢的机器，vCPU 总数不能超过配额。比如一台 p4d.24xlarge 就是 96 vCPU。
- 一次请求的 `InstanceCount` 范围是 **1–1000**。[文档：CreateCapacityReservation API]
- 可以建在 cluster placement group 里；spread 和 partition placement group 不支持。[文档：Limitations]
- 不能转给别的账号，但可以通过 RAM **共享**。[文档]

### 2.6 一次请求：要么全给，要么不给

一次 `CreateCapacityReservation` 只会建**一个**预留，数量就是你请求的数量。[文档：API] 没有"能给几台给几台"的参数。[推断：API 里找不到这种参数，实测中 ICE 时也没有拿到过部分数量]
→ 想拿到部分容量，只能自己**把请求拆小**。官方排障文档也是这么建议的。

### 2.7 AZ 名字和 AZ ID

- `eu-central-1a` 这样的 AZ 名字，在**每个账号里对应的物理 AZ 是随机的**；要用 **AZ ID**（比如 `euc1-az2`）才能跨账号对齐。[文档：RAM AZ IDs]
- `CreateCapacityReservation` 也可以直接传 `AvailabilityZoneId`。[文档：API]
  → 给客户写操作步骤时，如果涉及多个账号，要用 AZ ID 来说。

---

## 3. API 限流和重试

### 3.1 EC2 API 限流

- EC2 按**账号 + 区域**做限流，用的是 **token bucket（令牌桶）** 算法；超了就返回 `RequestLimitExceeded`。[文档：EC2 API throttling]
- `CreateCapacityReservation` 属于 **mutating（修改资源）** 类，令牌桶**最多 50 个，每秒补 5 个**。[文档]
- 这个桶是**所有 mutating API 共用的**，不是 ODCR 单独一个。[文档：表里的"All mutating API actions that are not …"]
  → 抢得太快，**会影响同一账号、同一区域里客户自己的 Auto Scaling、Terraform、CI 等**。
- `Describe*` 类：最多 100 个，每秒补 20 个。[文档]
- 官方建议用**指数退避 + 随机抖动**，并设上最大等待时间。[文档]

### 3.2 SDK / CLI 自带的重试

- AWS SDK 和 CLI v2 默认用 **standard** 重试模式，`max_attempts` 默认是 **3**，也就是 1 次请求 + 最多 2 次重试；设成 1 就不重试。[文档：SDK retry behavior]
- [实测] 在默认设置下，一次没抢到的 `create-capacity-reservation` 会在账号里留下 **3 条** `failed` 记录。5 个"机型 × AZ"组合，正好留下 15 条。说明 CLI **把 ICE 当成可重试的错误，自己又多发了 2 次**。
  → 这些看不见的重试会打乱我们自己的节奏，还会多消耗令牌，所以脚本里设了 `AWS_MAX_ATTEMPTS=1`。

### 3.3 幂等：ClientToken

- `ClientToken` 用来保证请求**幂等**。[文档：API]
- [实测] 用同一个 `ClientToken` 连发两次 `create-capacity-reservation`，**两次返回同一个预留 ID**，账号里也只有一个预留。
  → 如果碰到网络超时这类"**不知道成没成功**"的错误，**带同一个 token 再发一次**，就能拿到真实结果，不会多建一个。

---

## 4. 官方的另一个选择：Capacity Reservation Fleet

AWS 有一个原生的功能叫 **Capacity Reservation Fleet**，和本工具的目的很像：

| | Capacity Reservation Fleet | gpu-hunter.sh |
|---|---|---|
| 容量不够时 | **后台自动一直重试**，直到满足目标 [文档] | 脚本循环重试 |
| 抢满以后 | 预留被取消的话，**会自动补回来** [文档] | 不会 |
| 多个机型 | 可以，按优先级选（`prioritized`）[文档] | 可以，按你给的顺序 |
| **多个 AZ** | **不行**。[实测] API 报错："All InstanceTypeSpecifications must specify the same Availability Zone" | **可以** |
| open / targeted | **只支持 open** [文档] | 两种都支持 |
| 按权重算容量 | 支持（比如按 vCPU 算）[文档] | 不支持，只按台数算 |
| 单独管理每个预留 | 不行，只能整个 Fleet 一起改 [文档] | 可以 |
| 前提 | 第一次用要创建 service-linked role（需要 `iam:CreateServiceLinkedRole`）[实测] | 不需要 |
| 运行在哪 | AWS 托管，不用自己一直开着机器跑 | 要自己找台机器一直跑 |
| 额外费用 | 不收 [文档] | 不收（只收预留本身的钱） |

**怎么选**：
- **只要一个 AZ**、用 open 模式就行 → **优先用官方的 Fleet**。它由 AWS 托管，被取消了还会自动补回来。
- **要多个 AZ 一起抢**、要 targeted 模式、或者想看每次尝试的详细数据 → 用本工具。也可以**每个 AZ 各建一个 Fleet**。[推断：没有实测过多个 Fleet 同时跑的效果]

> 注：我们的测试账号没有创建 service-linked role 的权限，所以 **Fleet 后台自动重试的效果没有实测**，上面写的都来自官方文档。

---

## 5. gpu-hunter.sh 的设计和机制的对应关系

| 机制 | 设计 |
|---|---|
| ICE 时官方建议换 AZ、换机型 [文档] | 按你给的机型顺序，在每个有这个机型的 AZ 里都试；先用 `describe-instance-type-offerings` 过滤掉根本没有的组合 |
| 一次请求要么全给要么不给 [文档/推断] | 没容量就**减半再试**（4 → 2 → 1），抢到几台先占几台 |
| 容量变化很频繁 [文档] + 限流桶是共用的 [文档] | 每轮失败后等待时间乘 1.5，从 30 秒到 300 秒，加随机抖动；碰到限流直接等最长时间 |
| CLI 默认会偷偷重试 ICE [实测] | `AWS_MAX_ATTEMPTS=1`，重试节奏完全由脚本控制 |
| `pending` 可能要 5 分钟才变 `active` [文档] | 创建成功就算抢到，**不会取消 pending 的预留**；只有返回 `failed` 才算没抢到 |
| 网络超时时不知道成没成功 | 带**同一个 ClientToken** 最多再发 2 次 [实测幂等有效] |
| 响应丢失等情况的兜底 | 每轮开始前按本次运行的 tag（`gpu-hunter-run`）去 AWS 查已经拿到了多少。因为查询是最终一致的，这个数字**只用来调低剩余数量，不会调高**，以免多抢 |
| `pending` 状态不能取消 [文档：Cancel 页列出的可取消状态里没有 pending] | `--release` 失败时会提示过几分钟再运行一次 |
| 配额错误重试没用 [文档] | 碰到配额、权限、参数错误马上停（退出码 3） |
| 没有查询权限的话，抢到了也没法确认 | 开始前先检查 `DescribeCapacityReservations` 权限 |
| 按秒计费，不用也收钱 [文档] | 每个预留都打 tag，`--status` 查看，`--release` 一键释放 |
| open 模式会吃掉现有的实例 [文档] | 提供 `--targeted` |

---

## 6. 速度

### 6.1 单次请求有多快 [实测]

测试方法：在**东京区域**的一台开发机上，用 AWS CLI v2 调用接口。

| 调用 | 调法兰克福（跨区域） | 调本区域 |
|---|---|---|
| `create-capacity-reservation --dry-run` | 1275–1352 ms（8 次） | — |
| 真实创建 t3.micro 预留 | 约 1490 ms（3 次），**响应里直接就是 `active`** | — |
| `describe-capacity-reservations` | 1261–1333 ms | **约 395 ms** |
| `aws --version`（只是 CLI 启动） | 约 160 ms | |

结论：
- 每次调用里，**大约 1 秒花在跨区域网络上**，CLI 启动本身约 0.16 秒。
- **在同一个区域里跑**（比如在目标区域开一台小机器，或者用 CloudShell），每次请求大约能从 1.3 秒降到 0.4 秒左右。[推断：根据本区域 describe 的数据]
- 实测时，立即生效的预留在创建的响应里就已经是 `active`，所以脚本不再额外查询一次状态。

### 6.2 一轮要多久

一轮最多发出的请求数 ≈ **机型数 × AZ 数 × 减半次数**。减半次数 ≈ log2(数量) + 1。

例子：2 个机型 × 3 个 AZ × 要 8 台（8→4→2→1，4 次）= **24 次请求**。
- 跨区域运行约 24 × 1.4 秒 ≈ **34 秒**，本区域运行约 24 × 0.4 秒 ≈ **10 秒**。
- 每秒最多约 1 次请求，远低于 mutating 桶每秒补 5 个令牌的速度，**不会把客户的令牌桶用光**。[推断]
- 再加上轮与轮之间的等待（30 → 300 秒）。

### 6.3 "抢得快"到底取决于什么

- **主要取决于什么时候有容量被释放出来**（别的用户关机、AWS 加机器），这个脚本控制不了。[推断]
- 脚本能控制的：**多快发现**空出来的容量（检查频率）、**能覆盖多少地方**（机型和 AZ 越多越好）、**能不能先拿一部分**（减半）。
- 检查得太频繁效果不一定更好：会消耗共用的令牌桶，也会留下大量 `failed` 记录。默认的 30–300 秒是一个比较保守的起点，**没有经过大规模验证**。

---

## 7. 怎么评估效果

### 7.1 每次运行都会记录的数据

- **事件文件** `gpu-hunter-events-<run id>.csv`（每次运行一个文件）：每次 API 尝试记一行，字段是 时间、已运行秒数、第几轮、机型、AZ、请求数量、结果、API 耗时。
  结果的取值：`won-active`、`won-pending`、`no-capacity`、`failed-state`、`throttled`、`aws-or-network-error`、`quota`、`fatal`、`dry-run`。
- **结束时打印的一行统计**：抢到几台、用时、轮数、请求次数、成功次数、没容量次数、被限流次数、第一次抢到用了多久、抢满用了多久。
- **汇总工具**：`tools/report.sh gpu-hunter-events-<run id>.csv`，会按"机型 × AZ"列出请求次数、成功率、平均 API 耗时，还有 API 耗时的中位数和 p90。

### 7.2 看哪些指标

| 指标 | 怎么算 | 说明什么 |
|---|---|---|
| **第一次抢到用时**（time to first） | 开始到第一次抢到 | 最快多久能开始用 |
| **抢满用时**（time to full） | 开始到抢满目标 | 整体效果，最重要 |
| **完成率**（fill rate） | 抢到台数 ÷ 目标台数，按时间画出来 | 抢不满的时候能拿到多少 |
| **每抢到 1 次要请求几次** | 请求次数 ÷ 成功次数 | 效率，也代表消耗了多少令牌 |
| **各个机型 × AZ 的成功率** | report.sh 的表 | 哪里更容易抢到，下次把它排在前面 |
| **被限流次数** | `throttled` 的数量 | 应该是 0；不是 0 就把间隔调大 |
| **闲置成本** | 预留的台时 − 实际在用的台时，再乘以按需单价 | 抢到了但没用上，浪费了多少钱 |

闲置成本可以用 CloudWatch 的 ODCR 指标来看：`InstanceUtilization`、`UsedInstanceCount`、`AvailableInstanceCount`。另外，预留使用率低于 20% 时，AWS Health 会发出 `AWS_EC2_ODCR_UNDERUTILIZATION_NOTIFICATION` 事件，可以接 EventBridge。[文档：CloudWatch metrics、Monitor underutilization]

### 7.3 怎么做对比，才比较公平

容量是**一直在变的**，同一个配置今天和明天的结果可能差很多，所以：

1. **一定要有基线**：比如"人工每 10 分钟点一次控制台"或者"固定 60 秒间隔、只试一个 AZ"，拿它来跟本工具比**抢满用时**。
2. **时间要交替**：A、B 两种配置轮流跑（A 一小时、B 一小时，重复几次），不要一个在白天跑、一个在晚上跑。
3. **不要在同一个账号里同时跑两种配置**：它们会互相抢同一批容量，还会共用一个令牌桶。
4. **每个配置至少跑几次**，看中位数，不要只看一次的结果。
5. **和官方 Fleet 对比**：在同一个 AZ 里，分别用 Fleet 和本工具抢同一个机型，比较抢满用时。（我们没有做过这个对比。）
6. 数量少的时候结果波动很大，**不要根据一两次的结果下结论**。

### 7.4 我们已经验证过的

| 测试 | 结果 |
|---|---|
| 16 个离线测试（用假的 aws 命令模拟 ICE、`failed` 状态、`pending`、响应丢失、配额、没权限、参数错误等） | 全部通过 |
| 用真实 API 跑 `--dry-run` | 通过 |
| 真实创建预留、用 `--status` 查、用 `--release` 释放（t3.micro） | 通过 |
| 真实 ClientToken 幂等 | 同一个 token 发两次，拿到同一个 ID |
| 在一个测试 VPC 的私有子网里抢 1 台 g6.xlarge | 第一轮碰到真实的 ICE，第二轮（开始后约 45 秒）抢到；在预留里开机器，自动用上了预留；`nvidia-smi` 看到 NVIDIA L4；机器 terminate 以后预留还在；释放成功 |

**没有验证过的**：大数量（几十台以上）、P 系列（p4d/p5/p5en）真实抢购、连续很多小时的运行、和官方 Fleet 的效果对比。

---

## 8. 风险和局限

- **不保证能抢到**：容量是 AWS 的，脚本只能提高"发现空出来的容量"的机会。
- **会产生费用**：预留生效以后按按需价收费，用不用都收，最少收 60 秒。**一定要记得释放**。
- **open 模式会吃掉现有的实例**（见 2.2）。
- **会消耗共用的 API 令牌桶**（见 3.1），间隔不要调得太小。
- **会留下 `failed` 记录**：不收费，60 分钟后看不到；但在控制台里看起来会比较乱。
- **脚本退出后不会再管预留**：它不会像官方 Fleet 那样，预留被取消了还自动补回来。
- 这是用 bash 写的演示代码，**没有做生产级别的错误处理、监控和审计**。

---

## 参考资料（AWS 官方文档）

- [Reserve compute capacity with EC2 On-Demand Capacity Reservations](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-capacity-reservations.html)
- [Create a Capacity Reservation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/capacity-reservations-create.html)
- [View the state of a Capacity Reservation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/capacity-reservations-view.html)
- [Capacity Reservation pricing and billing](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/capacity-reservations-pricing-billing.html)
- [Cancel a Capacity Reservation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/capacity-reservations-release.html)
- [CreateCapacityReservation API](https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_CreateCapacityReservation.html)
- [Capacity Reservation Fleets](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/cr-fleets.html) / [Concepts](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/crfleet-concepts.html)
- [Request throttling for the Amazon EC2 API](https://docs.aws.amazon.com/ec2/latest/devguide/ec2-api-throttling.html)
- [Retry behavior (AWS SDKs and Tools)](https://docs.aws.amazon.com/sdkref/latest/guide/feature-retry-behavior.html)
- [Troubleshoot Amazon EC2 instance launch issues](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/troubleshooting-launch.html)
- [Monitor Capacity Reservations with CloudWatch](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/capacity-reservation-cw-metrics.html) / [Monitor underutilization](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/cr-eventbridge.html)
- [Availability Zone IDs](https://docs.aws.amazon.com/ram/latest/userguide/working-with-az-ids.html)
