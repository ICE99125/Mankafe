# 接口说明

漫画 / 轻小说 / 动画 / 写真四类内容复用同一套服务端信封。
代码入口：`lib/services/api_endpoints.dart`（路径、公共头）、
`lib/services/repository.dart`（每个参数怎么拼）。

## 1. 基础约定

| 项 | 说明 |
| --- | --- |
| 线路 | 主线路 `https://api.copy202602.com`，备用 `api.copy202601.com`、`api.manga2026.xyz`、`mapi.mangacopy.com`；启动时并行探活，`/api/v3/system/network2` 会下发动态域名 |
| 信封 | `{code, message, results}`，`code != 200` 即业务错误；`results` 的类型由接口决定 |
| 分页信封 | `{list, total, limit, offset}`，用 `limit` + `offset` 翻页 |
| 公共 query | 所有请求都带 `platform=3` |
| 缓存 | 列表/榜单 10 分钟、详情 30 分钟、章节目录与配置 6 小时、评论 3 分钟、章节图片地址 7 天；`/member`、`/login`、`/upload` 不缓存 |
| 重试 | 同线路重试一次 → 换一条已探活线路再试一次；业务错误不重试 |

## 2. 公共请求头

18 个，GET/POST 共用，全部由 `apiHeaders()` 生成：

```text
user-agent      COPY/3.1.0            accept          application/json
content-type    application/x-www-form-urlencoded
Accept-Language zh-CN,zh;q=0.9        source          copyApp
platform        3                     version         3.1.0
versionCode     84                    region          1
webp            1                     referer         com.copymanga.app-3.1.0
device          V417IR（androidId）     deviceInfo      V2203A-PD2203
pseudoID        16 位随机指纹           umString        b4c89ca4104ea9a97750314d791520ac
dt              2026.11.16            authorization   Token <token>
X-Auth-Timestamp  Unix 秒             X-Auth-Signature 见下
```

签名：`X-Auth-Signature = lowerHex(HMAC-SHA256(key=tapString, message=秒级时间戳))`，
与 `X-Auth-Timestamp` 用同一个时间戳，不含 method/path/body。

写接口（登录、评论、收藏）还要把同一批身份字段（`androidId`、`deviceInfo`、
`pseudoID`、`dt`、`tapString`…）放进 **form body**，见 `DeviceProfile.formFields()`。

## 3. 请求参数怎么拿

| 参数 | 取值来源 |
| --- | --- |
| `platform` | 固定 `3` |
| `limit` / `offset` | 分页。列表默认 21（写真 18、章节 100、评论 20），`offset` 按 `limit` 递进 |
| `ordering` | 排序：`-datetime_updated`（最新）/ `-popular`（最热），负号表示降序 |
| `free_type` | 漫画/小说/动画列表固定 `0`；写真不带 |
| `path_word` | 列表条目里的 `path_word`，拼详情、专题、章节路径 |
| `uuid` | 列表条目里的 `uuid`（写真/动画/轻小说详情与章节都用它） |
| `comic_id` / `book_id` / `post_id` / `cartoon_id` | 详情响应内层对象（`results.comic/book/post/cartoon`）的 `uuid` |
| `chapter_id` | 章节目录里的章节 **uuid**（不是序号）；吐槽接口认这个参数名 |
| `reply_id` | 评论 id。顶层评论列表**不要带**，查某条评论的全部回复时传 |
| `comment_id` / `roast_id` | 要删除的那条评论 / 吐槽自己的 id |
| `theme` / `author` / `parody` / `tag` / `company` / `mannequin` | 题材、标签接口返回的 `path_word`（传中文名返回 `total=0`） |
| `q` | 搜索框输入 |
| `type` / `date_type` / `audience_type` | 榜单：`1` 漫画、`5` 轻小说；`day/week/month/total`；`male/female` |
| `line` | 播放线路 `line1` / `line2` / `line3` |
| `pos` | 推荐位槽位码，客户端按频道写死（动画推荐 `3200301`） |
| `date` | 写真最新列表固定传空串（服务端忽略） |
| `in_mainland` | 漫画章节目录固定 `1`，缺省会返回 `total=0` |
| `is_collect` | `1` 收藏 / `0` 取消，同一个端点 |
| `token` | `POST /api/v3/login` 的 `results.token` |

## 4. 接口清单

### 系统 / 配置

| 方法 | 路径 | 参数 | 返回 `results` |
| --- | --- | --- | --- |
| GET | `/api/v3/system/network2` | — | `api_list`（线路域名）、`static`（图片 CDN 域名） |
| GET | `/api/v3/system/config/2020/3` | — | 服务端配置 |
| GET | `/api/v3/comment/config` | — | `report_type`、`report_tip` |
| GET | `/api/v3/system/appVersion/last` | — | `android/ios/androidTest: {name, update, version, url, forced}` |

### 首页 / 聚合

| 方法 | 路径 | 参数 | 返回 `results` |
| --- | --- | --- | --- |
| GET | `/api/v3/h5/homeIndex2` | `platform=3` | `banners` `topics` `recComics` `hotComics` `newComics` `rankDayComics` `rankWeekComics` `rankMonthComics` `finishComics`（区块可能是裸数组或 `{list,total}`） |
| GET | `/api/v3/h5/cartoonIndex` | — | 动画频道的专题 / 推荐 / 标签 / 排序 / 轮播 |
| GET | `/api/v3/h5/postIndex` | — | 写真的周榜 / 月榜 / 最新 / 轮播 |

### 内容列表

| 方法 | 路径 | 参数 | 返回 `results` |
| --- | --- | --- | --- |
| GET | `/api/v3/comics` | `limit` `offset` `ordering` `theme` `free_type` `top=finish` | 漫画条目 |
| GET | `/api/v3/books` | 同上（无 `top`） | 轻小说条目 |
| GET | `/api/v3/cartoons` | `limit` `offset` `ordering` `theme` `company` `free_type` | 动画条目 |
| GET | `/api/v3/posts` | `mannequin` `tag` `ordering` `limit` `offset` | 写真条目 |
| GET | `/api/v3/update/newest` | `limit` `offset` | 最近更新漫画 |
| GET | `/api/v3/update/post/newest` | `date` `limit` `offset` | 最近上架写真 |
| GET | `/api/v3/ranks` | `type` `date_type` `audience_type` `limit` `offset` | `list: [{sort, rise_num, popular, comic 或 book}]` |
| GET | `/api/v3/recs` | `pos` `limit` `offset` | `list: [{type, comic}]`、`total` |
| GET | `/api/v3/topics` | `limit` `offset` `type` | 专题列表（动画专题 `type=21`） |

条目关键字段：`uuid` `path_word` `name` `alias` `cover` `author{name,path_word}`
`theme{…}` `status` `popular` `datetime_updated` `last_chapter` `brief`。

### 题材 / 标签 / 专题

| 方法 | 路径 | 参数 | 返回 `results` |
| --- | --- | --- | --- |
| GET | `/api/v3/theme/comic/count` | — | `list: [{name, path_word, count}]` |
| GET | `/api/v3/theme/book/count` | — | 同上（轻小说） |
| GET | `/api/v3/theme/cartoon/count` | — | 同上（动画） |
| GET | `/api/v3/tag/post/count` | — | 同上（写真标签） |
| GET | `/api/v3/topic/{path_word}` | — | `title` `cover` `brief` 等专题信息 |
| GET | `/api/v3/topic/{path_word}/contents` | `limit` `offset` | 专题内作品列表 |

### 漫画

| 方法 | 路径 | 参数 | 返回 `results` |
| --- | --- | --- | --- |
| GET | `/api/v3/comic2/{path_word}` | — | `comic{…}`、`groups{path_word: {name, count}}` |
| GET | `/api/v3/comic/{path_word}/group/{group}/chapters` | `limit` `offset` `in_mainland=1` | `list: [{uuid, name, index, size, datetime_created}]`、`total` |
| GET | `/api/v3/comic/{path_word}/chapter2/{chapter_uuid}` | — | `chapter.contents: [{url, width, height}]`、`next`、`prev` |

### 轻小说

| 方法 | 路径 | 参数 | 返回 `results` |
| --- | --- | --- | --- |
| GET | `/api/v3/book/{path_word}` | — | `book{…}`、`popular` |
| GET | `/api/v3/book/{path_word}/volumes` | `limit` `offset` | `list: [卷]`、`total` |
| GET | `/api/v3/book/{path_word}/volume/{volume_id}` | — | `volume{name, contents, txt_addr, txt_encoding}` |
| GET | `txt_addr`（CDN） | — | 卷正文纯文本，非 JSON；按 `txt_encoding`（实测 GBK）解码 |

### 动画

| 方法 | 路径 | 参数 | 返回 `results` |
| --- | --- | --- | --- |
| GET | `/api/v3/cartoon/{path_word}` | — | `cartoon{…}`、`collect`（null=未收藏） |
| GET | `/api/v3/cartoon/{path_word}/chapters` | `limit` `offset` | `list: [集]`、`total` |
| GET | `/api/v3/cartoon/{path_word}/chapter/{uuid}` | `line` | `chapter.video`（HLS `.m3u8`）。需登录，未开放线路回 `code=210` |

### 写真

| 方法 | 路径 | 参数 | 返回 `results` |
| --- | --- | --- | --- |
| GET | `/api/v3/post/{uuid}` | — | `post{…}` |
| GET | `/api/v3/post/{uuid}/chapters` | `limit` `offset` | `list: [章]`、`total` |
| GET | `/api/v3/post/{uuid}/chapter/{chapter_id}` | — | `chapter.contents: [{url}]` |

### 搜索

| 方法 | 路径 | 参数 | 返回 `results` |
| --- | --- | --- | --- |
| GET | `/api/v3/search/comic` | `format=json` `q` `limit` `offset` | `list` + `total` |
| GET | `/api/v3/search/books` | `q` `limit` `offset` `ordering` `free_type` | 同上 |
| GET | `/api/v3/search/cartoons` | 同上 | 同上 |
| GET | `/api/v3/search/posts` | 同上（无 `free_type`） | 同上 |

### 收藏 / 浏览记录（需登录）

| 方法 | 路径 | 参数 | 返回 |
| --- | --- | --- | --- |
| GET | `/api/v3/member/collect/{comics\|books\|posts\|cartoons}` | `limit` `offset` `ordering` `free_type` | 收藏列表；条目带 `last_browse` 可续读 |
| POST | `/api/v3/member/collect/{comic\|book\|post\|cartoon}` | form：`{comic_id\|book_id\|post_id\|cartoon_id}` + `is_collect` + 身份字段 | `{success: bool}`，失败时 `error` |
| GET | `/api/v3/member/browse/{comics\|books\|posts\|cartoons}` | `limit` `offset` | 浏览记录列表 |
| DELETE | `/api/v3/member/browse/{comics\|books\|posts\|cartoons}` | — | 清空该类浏览记录 |

### 评论 / 吐槽

| 方法 | 路径 | 参数 | 返回 `results` |
| --- | --- | --- | --- |
| GET | `/api/v3/comments` | `comic_id` `limit` `offset` `platform`（**不带 `reply_id`**） | `list: [评论]`、`total`、`close_comment` |
| GET | `/api/v3/comments` | `comic_id` `reply_id` `limit` | 该评论下**全部层级**的回复（扁平数组） |
| POST | `/api/v3/member/comment` | form：`comic_id` `comment` `reply_id` + 身份字段 | 无（成功后重新拉列表） |
| DELETE | `/api/v3/member/comment` | form：`comic_id` `comment_id` + 身份字段 | 无 |
| GET | `/api/v3/bookcomments` | `book_id` `limit` `offset` `platform` | 同评论信封 |
| POST | `/api/v3/member/bookcomment` | form：`book_id` `comment` `reply_id` | 无 |
| DELETE | `/api/v3/member/bookcomment` | form：`book_id` `comment_id` | 无 |
| GET | `/api/v3/roasts` | `chapter_id`（= 章节 uuid）`limit` `offset` `platform` | `list`、`total`、`close_roast` |
| POST | `/api/v3/member/roast` | form：`chapter_id` `roast` `reply_id` | 无 |
| DELETE | `/api/v3/member/roast` | form：`chapter_id` `roast_id` | 无 |

评论条目主要字段：`id` `user{id,name,avatar}` `comment` `count` `datetime_created`
`parent_id` `parent_user_name`。回复不在顶层列表里，要按 `reply_id` 单独拉。

### 账号

| 方法 | 路径 | 参数 | 返回 `results` |
| --- | --- | --- | --- |
| POST | `/api/v3/login` | form：`username` `password`(= `base64(明文 + "-" + salt)`) `salt` + 身份字段 | `token`、`user{user_id, username, nickname, avatar, gender}` |
| POST | `/api/v3/register` | form：`username` `password` `salt` `invite_code`(可选) + 身份字段 | 无（注册后手动登录） |
| GET | `/api/v3/member/info` | — | 账号资料（本项目未使用，登录返回里已带 `user`） |
| POST | `/api/v3/member/update/info` | JSON：`nickname` `gender` `avatar` | `{success: bool}` |
| POST | `/api/v3/upload/image/1` | multipart，字段 `file` | 图片相对路径字符串（用 CDN 域名拼完整 URL） |

## 5. 错误处理

| 情况 | 处理 |
| --- | --- |
| `code != 200` | 抛业务错误，展示 `message`（如 `210` 表示参数 / 线路不可用） |
| HTTP 401 或 `code=401` | 已带 token → 登录过期；未登录访问鉴权接口 → 提示登录 |
| HTTP 502/503/504 | 视为线路不可达，换线路重试 |
| 200 但不是 JSON | 报「响应格式异常」，不当作网络失败，不换线路 |

## 6. 明确不实现的接口

广告（`/api/sdk/ad/*`、`/api/v2/adopr/*`、`/member/ads/verify`）；
交易 / 会员 / 奖励（`orders`、`post/buy`、`topic/buy`、`rewards`、`goods`）；
自更新下载（只读 `/system/appVersion/last` 做展示）；
离线下载（`/chapterdownload/`、`/chapter2download/`）；
购买状态聚合（`/comic/{path_word}/query`）。
章节一律按可读处理，忽略响应里的 `is_lock` / `is_buy` / `is_vip`。
