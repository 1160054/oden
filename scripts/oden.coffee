# Description
#  レビュー依頼Bot
#
# Dependencies:
#   "request": "2.78.0"
#   "cron": "1.1.0"
#
# Configuration:
#   CHANNEL - チャネル名
#   SELECT_NUM - レビューに必要な人数
#   FETCH_CRON - ユーザーのオンラインをチェックする間隔
#   SKIP_CRON  - スキップされたユーザーを復活させる間隔
#   CLEAR_CRON - オフラインユーザーをユーザーから外す間隔
#   JSON_PATH  - 永続化用JSONファイルのパス
#   SUPER_USER
#
# Commands:
#    pr - レビュワーを選ぶ
#    users      - ユーザーを表示
#    user+(.*)  - ユーザーを追加する
#    user-(.*)  - ユーザーをスキップする
#    skips      - スキップされたユーザーを表示
#    nevers     - 削除されたユーザーを表示
#    never+(.*) - ユーザーを削除
#    never-(.*) - ユーザーの削除を取り消す
#    config - botの設定を表示する
#
# Author:
#  s1160054
#

request = require('request')
cronJob = require('cron').CronJob
fs      = require ('fs')

select_num   = process.env.SELECT_NUM  || 2
channel_name = process.env.CHANNEL     || 'random'
super_user   = process.env.SUPER_USER  || 'admin'
fetch_cron   = process.env.FETCH_CRON  || '*/10 *   * * *'
clear_cron   = process.env.CLEAR_CRON  || '0    */1 * * *'
skip_cron    = process.env.SKIP_CRON   || '0    0   * * *'
path         = process.env.JSON_PATH   || './db.json'
token        = process.env.HUBOT_SLACK_TOKEN

module.exports = (robot) ->
  robot.brain.setAutoSave false

  load = ->
    robot.logger.info "load"
    data = JSON.parse fs.readFileSync path, encoding: 'utf-8'
    robot.brain.mergeData data
    robot.brain.setAutoSave true

  save = (data) ->
    robot.logger.info "save"
    fs.writeFileSync path, JSON.stringify data

  robot.brain.on 'loaded', save
  load()

  robot.logger.info config()
  fetch_users(robot)

  # 設定を表示する
  robot.respond /config/, (msg) =>
    msg.send "\n#{config().join('\n')}"

  # レビュワーを選ぶ
  robot.respond /pr/, (msg) =>
    users = get(robot, 'users')
    never_users = get(robot, 'never_users')
    skip_users = get(robot, 'skip_users')
    my_name = msg.message.user.name
    for name in [super_user, my_name] + never_users + skip_users
      skip_idx = users.indexOf(name)
      users.splice(skip_idx, 1) if skip_idx != -1
    if users.length < select_num
      msg.send("アサインできるレビュワーが #{users.length} 名です\n")
      return
    users = random_fetch(users, select_num)
    msg.send("@#{users.join(' @')}")

  # ユーザーをスキップ
  robot.respond /user-(.*)/, (msg) =>
    user = msg.match[1]
    user = msg.message.user.name if /me/.test(user)
    add(robot, 'skip_users', user)
    rm(robot, 'users', user)

  # ユーザーを追加
  robot.respond /user\+(.*)/, (msg) =>
    user = msg.match[1]
    user = msg.message.user.name if /me/.test(user)
    add(robot, 'users', user)
    rm(robot, 'skip_users', user)

  # ユーザーを表示
  robot.respond /users/, (msg) =>
    users = get(robot, 'users')
    msg.send("レビュー可能なユーザー: \n#{users.join(', ')}")

  # スキップリストを表示
  robot.respond /skips/, (msg) =>
    skip_users = get(robot, 'skip_users')
    msg.send("スキップしたユーザー: \n#{skip_users.join(', ')}")

  # ユーザーを復活
  robot.respond /never-(.*)/, (msg) =>
    user = msg.match[1]
    user = msg.message.user.name if /me/.test(user)
    add(robot, 'users', user)
    rm(robot, 'never_users', user)

  # ユーザーを削除
  robot.respond /never\+(.*)/, (msg) =>
    user = msg.match[1]
    user = msg.message.user.name if /me/.test(user)
    add(robot, 'never_users', user)
    rm(robot, 'users', user)

  # 削除されたユーザーを表示
  robot.respond /nevers/, (msg) =>
    never_users = get(robot, 'never_users')
    msg.send("削除されたユーザー: \n#{never_users.join(', ')}")

  # スキップリストをリセット
  new cronJob(skip_cron, () ->
    robot.brain.set('skip_users', [])
    robot.logger.info "skip"
  ).start()

  # ユーザーリストをリセット
  new cronJob(clear_cron, () ->
    robot.brain.set('users', [])
    robot.logger.info "clear"
  ).start()

  # ユーザーリストを更新
  new cronJob(fetch_cron, () ->
    fetch_users(robot)
    robot.logger.info "fetch"
  ).start()

  # 生存確認
  robot.router.get '/', (req, res) ->
    res.send 'pong'

##################################################

# 設定を配列で返す
config = () ->
  ["レビュワー: `#{select_num}人`",
   "チャンネル: `#{channel_name}`",
   "オンラインユーザー追加: `#{fetch_cron}`",
   "オフラインユーザー削除: `#{clear_cron}`",
   "レビュースキップの取消: `#{skip_cron}`",]

# ユーザーを更新する
fetch_users = (robot) ->
  users = get(robot, 'users')
  robot.logger.info "List: #{users.join(', ')}"
  groups_list = "https://slack.com/api/groups.list?token=#{token}&pretty=1"
  request.get groups_list, (error, response, body) =>
    data = JSON.parse(body)
    target_channel = null
    for group in data.groups
      target_channel = group if group.name == channel_name
    if target_channel
      user_ids = target_channel.members.sort -> Math.random()
      for user_id in user_ids
        check_online(robot, user_id)
    else
      channels_list = "https://slack.com/api/channels.list?token=#{token}&pretty=1"
      request.get channels_list, (error, response, body) =>
        data = JSON.parse(body)
        for channel in data.channels
          target_channel = channel if channel.name == channel_name
        user_ids = target_channel.members.sort -> Math.random()
        for user_id in user_ids
            check_online(robot, user_id)

# ユーザーを追加する
check_online = (robot, user_id) ->
  do (user_id) ->
    users_getPresence = "https://slack.com/api/users.getPresence?token=#{token}&user=#{user_id}&pretty=1"
    request.get users_getPresence, (error, response, body) =>
      data = JSON.parse(body)
      if (data.presence == "active")
        users_info = "https://slack.com/api/users.info?token=#{token}&user=#{user_id}&pretty=1"
        request.get users_info, (error, response, body) =>
          data = JSON.parse(body)
          return if data.user.is_bot
          user_name = data.user.name
          never_users = get(robot, 'never_users')
          skip_users = get(robot, 'skip_users')
          return if (never_users + skip_users).indexOf(user_name) != -1
          users = get(robot, 'users')
          robot.logger.info "Add:  #{user_name}" if users.indexOf(user_name) == -1
          users.push(user_name)
          robot.brain.set('users', uniq(users))

get = (robot, key) ->
    return (robot.brain.get(key) || []).slice(0)

rm = (robot, key, value) ->
    values = value.split(/[　・\s,、@]+/)
    arr = get(robot, key)
    for value in values
      skip_idx = arr.indexOf(value)
      arr.splice(skip_idx, 1) if skip_idx != -1
    robot.brain.set(key, arr)
    console.log "#{key} #{robot.brain.get(key, arr)}"
    return arr

add = (robot, key, value) ->
    values = value.split(/[　・\s,、@]+/)
    arr = get(robot, key)
    arr = arr.concat(values)
    arr = uniq(arr)
    arr.splice arr.indexOf(''), 1 if arr.indexOf('') != -1
    robot.brain.set(key, arr)
    console.log "#{key} #{robot.brain.get(key, arr)}"
    return arr

uniq = (ar) ->
  if ar.length == 0
    return []
  res = {}
  res[ar[key]] = ar[key] for key in [0..ar.length-1]
  value for key, value of res

random_fetch = (array, num) ->
  a = array
  t = []
  r = []
  l = a.length
  n = if num < l then num else l
  while n-- > 0
    i = Math.random() * l | 0
    r[n] = t[i] or a[i]
    --l
    t[i] = t[l] or a[l]
  r
