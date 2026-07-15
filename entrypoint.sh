#!/bin/bash
# Entrypoint script for Hermes Agent on Hugging Face Spaces
# 基于 Hermes Agent 真实 config.yaml 格式（source: cli-config.yaml.example + hermes_cli/config.py）
#
# 启动架构:
#   entrypoint.sh
#     ├── data_sync daemon (后台, 数据持久化)
#     ├── hermes gateway run (后台, API Server :8642 + 消息平台)
#     └── node /opt/hermes-web-ui/dist/server/index.js (前台, BFF :7860, 替代 hermes dashboard)

set -e

echo "🚀 Hermes Agent v0.10.0 - Hugging Face Spaces"
echo "=============================================="

# 检查必要的环境变量
if [ -z "$HF_DATASET_REPO" ]; then
    echo "⚠️  警告: HF_DATASET_REPO 未设置，数据将不会持久化到 Dataset"
fi

# ==================== 初始化目录 ====================
echo "📁 初始化目录结构..."
mkdir -p /data/.hermes/{cron,sessions,logs,memories,skills,pairing,hooks,image_cache,audio_cache,whatsapp/session}
mkdir -p /data/.hermes-web-ui
mkdir -p /app/logs

# ==================== 数据恢复 ====================
# 跳过从 Dataset 恢复 config.yaml（由本脚本根据环境变量重新生成）
export SKIP_CONFIG_RESTORE=true

if [ -n "$HF_DATASET_REPO" ]; then
    echo "📥 从 Dataset 恢复数据..."
    python -m src.data_sync restore || {
        echo "⚠️  数据恢复失败，使用空配置启动"
    }
fi

# ==================== 会话模型同步 ====================
# 解决模型切换后历史记录"消失"问题：
# 将所有历史会话的 model 字段更新为当前模型，使 Web UI 显示所有记录
echo "🔄 同步历史会话模型配置..."
python3 << 'SESSION_SYNC'
import json, os, glob
from pathlib import Path

current_model = os.environ.get('HERMES_MODEL', os.environ.get('MODEL_NAME', ''))
if not current_model:
    print("   ⚠️ 未配置模型，跳过会话同步")
    exit(0)

sessions_dir = Path('/data/.hermes/sessions')
if not sessions_dir.exists():
    print("   ⚠️ 会话目录不存在")
    exit(0)

updated = 0
for session_file in sessions_dir.glob('*.json'):
    try:
        with open(session_file, 'r', encoding='utf-8') as f:
            data = json.load(f)
        
        # 保留原始 model 信息
        if 'original_model' not in data and 'model' in data:
            data['original_model'] = data['model']
        
        # 更新 model 字段为当前模型（使 Web UI 显示此会话）
        if data.get('model') != current_model:
            data['model'] = current_model
            with open(session_file, 'w', encoding='utf-8') as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
            updated += 1
    except Exception as e:
        print(f"   ⚠️ 处理 {session_file.name} 失败: {e}")

print(f"   ✅ 已同步 {updated} 个会话的模型配置")
SESSION_SYNC

# ==================== 模型配置系统 ====================
echo "🤖 配置模型系统..."

# ---- 供应商定义 ----
declare -A PROVIDER_MODELS=(
    ["xai"]="grok-4.3"
    ["nvidia"]="moonshotai/kimi-k2-thinking"
    ["siliconflow"]="deepseek-ai/DeepSeek-V4-Flash"
    ["openai"]="gpt-4o"
    ["anthropic"]="claude-3-5-sonnet-20241022"
    ["google"]="gemini-2.0-flash"
    ["gemini"]="gemini-2.5-flash"
    ["openrouter"]="meta-llama/llama-3.1-8b-instruct:free"
    ["longcat"]="LongCat-Flash-Thinking-2601"
)

declare -A PROVIDER_API_KEYS=(
    ["xai"]="XAI_API_KEY"
    ["nvidia"]="NVIDIA_API_KEY"
    ["siliconflow"]="SILICONFLOW_API_KEY"
    ["openai"]="OPENAI_API_KEY"
    ["anthropic"]="ANTHROPIC_API_KEY"
    ["google"]="GOOGLE_API_KEY"
    ["gemini"]="GEMINI_API_KEY"
    ["openrouter"]="OPENROUTER_API_KEY"
    ["longcat"]="LONGCAT_API_KEY"
)

declare -A PROVIDER_BASE_URLS=(
    ["xai"]="https://api.x.ai/v1"
    ["nvidia"]="https://integrate.api.nvidia.com/v1"
    ["siliconflow"]="https://api.siliconflow.cn/v1"
    ["openai"]="https://api.openai.com/v1"
    ["anthropic"]="https://api.anthropic.com/v1"
    ["google"]="https://generativelanguage.googleapis.com"
    ["gemini"]="https://generativelanguage.googleapis.com"
    ["openrouter"]="https://openrouter.ai/api/v1"
    ["longcat"]="https://api.longcat.chat/openai"
)

# ---- 检测主模型 ----
detect_main_model() {
    if [ -n "$MODEL_PROVIDER" ] && [ -n "$MODEL_NAME" ]; then
        echo "manual:$MODEL_PROVIDER:$MODEL_NAME"
        return
    fi
    for provider in xai nvidia siliconflow openai anthropic google openrouter longcat; do
        api_key_var="${PROVIDER_API_KEYS[$provider]}"
        if [ -n "${!api_key_var}" ]; then
            if [ -n "$MODEL_NAME" ]; then
                echo "auto:$provider:$MODEL_NAME"
            else
                echo "auto:$provider:${PROVIDER_MODELS[$provider]}"
            fi
            return
        fi
    done
    if [ -n "$GEMINI_API_KEY" ]; then
        echo "auto:gemini:${PROVIDER_MODELS[gemini]}"
        return
    fi
    echo "default:nvidia:${PROVIDER_MODELS[nvidia]}"
}

# Hermes Gateway 实际使用的 provider 名称映射
# 某些 provider 名称在 Gateway 中不被识别，需要映射为 'custom' 或其他有效名称
map_provider_for_gateway() {
    local provider="$1"
    case "$provider" in
        siliconflow)
            # Gateway 不认识 'siliconflow'，使用 'custom' 并保留 base URL
            echo "custom"
            ;;
        *)
            echo "$provider"
            ;;
    esac
}

# ---- 检测辅助模型 ----
detect_vision_model() {
    if [ -n "$VISION_MODEL" ]; then echo "$VISION_MODEL"; return; fi
    if [ -n "$GEMINI_API_KEY" ] || [ -n "$GOOGLE_API_KEY" ]; then echo "google/gemini-2.5-flash"; return; fi
    echo ""
}

detect_aux_model() {
    if [ -n "$AUX_MODEL" ]; then echo "$AUX_MODEL"; return; fi
    if [ -n "$OPENROUTER_API_KEY" ]; then echo "google/gemini-3-flash-preview"; return; fi
    if [ -n "$GEMINI_API_KEY" ] || [ -n "$GOOGLE_API_KEY" ]; then echo "google/gemini-2.0-flash"; return; fi
    echo ""
}

detect_delegation_model() {
    if [ -n "$DELEGATION_MODEL" ]; then echo "$DELEGATION_MODEL"; return; fi
    if [ -n "$SILICONFLOW_API_KEY" ]; then echo "Pro/moonshotai/Kimi-K2.5"; return; fi
    echo ""
}

# ---- 执行检测 ----
echo ""
echo "📋 模型配置检测："
echo "────────────────────────────────────────"

MAIN_DETECTED=$(detect_main_model)
IFS=':' read -r MAIN_MODE MAIN_PROVIDER MAIN_MODEL <<< "$MAIN_DETECTED"
echo "🎯 Main Model: $MAIN_PROVIDER/$MAIN_MODEL (模式: $MAIN_MODE)"

VISION_MODEL_VAL=$(detect_vision_model)
echo "👁️  Vision Model: ${VISION_MODEL_VAL:-auto-detect}"

AUX_MODEL_VAL=$(detect_aux_model)
echo "⚡ Aux Model: ${AUX_MODEL_VAL:-auto-detect}"

DELEGATION_MODEL_VAL=$(detect_delegation_model)
echo "💻 Delegation Model: ${DELEGATION_MODEL_VAL:-inherit-main}"

MAIN_BASE_URL="${PROVIDER_BASE_URLS[$MAIN_PROVIDER]}"
echo "   Base URL: $MAIN_BASE_URL"

echo "────────────────────────────────────────"

# ==================== 生成 config.yaml ====================
CONFIG_FILE="/data/.hermes/config.yaml"
echo "📝 生成 config.yaml (Hermes 真实格式)..."

# 推断辅助模型供应商
infer_provider() {
    local model_id="$1"
    if [[ "$model_id" == google/* ]]; then echo "google"
    elif [[ "$model_id" == openrouter/* ]]; then echo "openrouter"
    elif [[ "$model_id" == Pro/* ]]; then echo "custom"
    else echo "$MAIN_PROVIDER"; fi
}

# 映射 provider 为 Gateway 可识别的名称
GATEWAY_MAIN_PROVIDER=$(map_provider_for_gateway "$MAIN_PROVIDER")
VISION_PROVIDER_VAL=$(map_provider_for_gateway "$(infer_provider "$VISION_MODEL_VAL")")
AUX_PROVIDER_VAL=$(map_provider_for_gateway "$(infer_provider "$AUX_MODEL_VAL")")
DELEGATION_PROVIDER_VAL=$(map_provider_for_gateway "$(infer_provider "$DELEGATION_MODEL_VAL")")

echo "🔄 Gateway provider 映射: $MAIN_PROVIDER → $GATEWAY_MAIN_PROVIDER"

cat > "$CONFIG_FILE" << EOF
# Hermes Agent Configuration
# Generated by entrypoint.sh at $(date -Iseconds)
# 主模型配置
model:
  default: "$MAIN_MODEL"
  provider: "$GATEWAY_MAIN_PROVIDER"
  base_url: "$MAIN_BASE_URL"
# 辅助模型配置 (per-task overrides)
auxiliary:
  vision:
    provider: "${VISION_PROVIDER_VAL:-auto}"
    model: "${VISION_MODEL_VAL}"
    timeout: 120
    download_timeout: 30
  web_extract:
    provider: "${AUX_PROVIDER_VAL:-auto}"
    model: "${AUX_MODEL_VAL}"
    timeout: 360
  compression:
    provider: "${AUX_PROVIDER_VAL:-auto}"
    model: "${AUX_MODEL_VAL}"
    timeout: 120
  title_generation:
    provider: "${AUX_PROVIDER_VAL:-auto}"
    model: "${AUX_MODEL_VAL}"
    timeout: 30
  session_search:
    provider: "auto"
    model: ""
    timeout: 30
  skills_hub:
    provider: "auto"
    model: ""
    timeout: 30
  approval:
    provider: "auto"
    model: ""
    timeout: 30
  mcp:
    provider: "auto"
    model: ""
    timeout: 30
  flush_memories:
    provider: "auto"
    model: ""
    timeout: 30
# 子代理 (Delegation) 配置
delegation:
  model: "${DELEGATION_MODEL_VAL}"
  provider: "${DELEGATION_PROVIDER_VAL}"
  max_iterations: 50
  reasoning_effort: "medium"
# API Server 配置 (Web UI BFF 的上游代理目标)
api_server:
  enabled: true
  port: 8642
  host: "127.0.0.1"
# 终端配置
terminal:
  backend: local
  timeout: 300
  shell: /bin/bash
# 显示配置
display:
  skin: default
  show_tool_progress: true
  show_resume: true
  spinner: dots
# Agent 配置
agent:
  max_iterations: 50
  approval_mode: ask
  dangerous_command_approval: ask
  gateway_timeout: 300
# 记忆配置
memory:
  enabled: true
  provider: local
# 压缩配置
compression:
  enabled: true
  threshold: 0.50
# 定时任务
cron:
  enabled: true
  tick_interval: 60
EOF

echo "   ✅ 配置文件已生成"

# ==================== 合并用户配置（平台/channel 设置等） ====================
# 如果存在从 Dataset 恢复的 config.yaml.restored，将其中的用户修改区块合并到新生成的 config.yaml
# 合并策略：
#   - entrypoint.sh 控制的区块（model, auxiliary, delegation, api_server）：新生成的优先
#     （这些由 HF Spaces 环境变量决定，必须权威）
#   - 用户在 Web UI 中修改的区块（platforms, display, agent, memory, compression, cron, terminal）：
#     恢复的优先（保留用户的个性化设置，如 channel 行为、显示偏好等）
RESTORED_CONFIG="/data/.hermes/config.yaml.restored"
if [ -f "$RESTORED_CONFIG" ]; then
    echo "🔄 合并用户配置 (platforms, display, agent 等)..."
    python3 << 'MERGE_SCRIPT'
import yaml
import sys

GENERATED = '/data/.hermes/config.yaml'
RESTORED = '/data/.hermes/config.yaml.restored'

# 区块优先级定义：
# ENTRYPOINT_PRIORITY  → entrypoint.sh 生成的值优先（由 HF Spaces 环境变量控制）
# USER_PRIORITY        → 恢复的用户值优先（Web UI 中用户修改的偏好）
ENTRYPOINT_PRIORITY = {'model', 'auxiliary', 'delegation', 'api_server'}
USER_PRIORITY = {'platforms', 'display', 'agent', 'memory', 'compression', 'cron', 'terminal'}

try:
    with open(GENERATED) as f:
        generated = yaml.safe_load(f) or {}
    with open(RESTORED) as f:
        restored = yaml.safe_load(f) or {}

    merged = {}

    # 遍历所有出现在任一配置中的顶层键
    all_keys = set(list(generated.keys()) + list(restored.keys()))

    for key in all_keys:
        if key in ENTRYPOINT_PRIORITY:
            # 环境变量控制的区块：始终用新生成的值
            if key in generated:
                merged[key] = generated[key]
        elif key in USER_PRIORITY:
            # 用户偏好区块：优先用恢复的值，没有则用生成的默认值
            if key in restored:
                merged[key] = restored[key]
            elif key in generated:
                merged[key] = generated[key]
        else:
            # 未明确分类的区块：优先用恢复的值（保留用户可能做的修改）
            if key in restored:
                merged[key] = restored[key]
            elif key in generated:
                merged[key] = generated[key]

    with open(GENERATED, 'w') as f:
        yaml.dump(merged, f, default_flow_style=False, allow_unicode=True, sort_keys=False)

    # 统计合并了哪些区块
    merged_user_keys = [k for k in USER_PRIORITY if k in restored]
    merged_other_keys = [k for k in all_keys - ENTRYPOINT_PRIORITY - USER_PRIORITY if k in restored and k not in generated]
    print(f"   ✅ 已合并用户区块: {', '.join(merged_user_keys) if merged_user_keys else '无'}")

except Exception as e:
    print(f"   ⚠️ 合并配置失败: {e}，使用生成的默认配置")
    sys.exit(0)  # 不阻止启动
MERGE_SCRIPT
    # 合并完成后删除临时文件，避免被后续备份重复保存
    rm -f "$RESTORED_CONFIG"
else
    echo "   ℹ️ 无需合并（无恢复的用户配置）"
fi

# ==================== 导出供应商环境变量 ====================
echo "🌐 设置供应商环境变量..."

# 显式导出所有 API Key 和 Base URL，确保 Gateway 子进程能正确继承
# （某些版本的 Hermes CLI 可能依赖显式 export 的环境变量）
for var in XAI_API_KEY NVIDIA_API_KEY SILICONFLOW_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY GOOGLE_API_KEY GEMINI_API_KEY OPENROUTER_API_KEY LONGCAT_API_KEY; do
    if [ -n "${!var}" ]; then
        export "$var"
    fi
done

if [ -n "$XAI_API_KEY" ]; then
    export XAI_BASE_URL="${XAI_BASE_URL:-https://api.x.ai/v1}"
fi
if [ -n "$NVIDIA_API_KEY" ]; then
    export NVIDIA_BASE_URL="${NVIDIA_BASE_URL:-https://integrate.api.nvidia.com/v1}"
fi
if [ -n "$SILICONFLOW_API_KEY" ]; then
    export SILICONFLOW_BASE_URL="${SILICONFLOW_BASE_URL:-https://api.siliconflow.cn/v1}"
    # Gateway 可能不认识 'siliconflow' provider，但认识 'openai' provider
    # siliconflow 使用 OpenAI 兼容 API，因此复制 key 到 OPENAI_API_KEY 作为备选
    if [ -z "$OPENAI_API_KEY" ]; then
        export OPENAI_API_KEY="$SILICONFLOW_API_KEY"
        export OPENAI_BASE_URL="${SILICONFLOW_BASE_URL:-https://api.siliconflow.cn/v1}"
        echo "   ℹ️  已将 SILICONFLOW_API_KEY 复制到 OPENAI_API_KEY (Gateway 兼容性)"
    fi
fi
if [ -n "$GEMINI_API_KEY" ]; then
    export GEMINI_BASE_URL="${GEMINI_BASE_URL:-https://generativelanguage.googleapis.com}"
fi
if [ -n "$OPENROUTER_API_KEY" ]; then
    export OPENROUTER_BASE_URL="${OPENROUTER_BASE_URL:-https://openrouter.ai/api/v1}"
fi
if [ -n "$LONGCAT_API_KEY" ]; then
    export LONGCAT_BASE_URL="${LONGCAT_BASE_URL:-https://api.longcat.chat/openai}"
fi

# 导出 API Server 环境变量（确保 Gateway 以 API Server 模式启动）
export API_SERVER_ENABLED=true
export API_SERVER_PORT=8642
export API_SERVER_HOST=127.0.0.1

# 默认允许所有用户（Hugging Face Spaces 单用户场景，否则 Gateway 拒绝所有消息）
export GATEWAY_ALLOW_ALL_USERS="${GATEWAY_ALLOW_ALL_USERS:-true}"

# 导出 HERMES_HOME（确保 Gateway 能正确定位配置目录）
export HERMES_HOME=/data/.hermes

# 导出 HERMES_MODEL 环境变量（进程级覆盖，影响 cron 等调度任务的模型选择）
export HERMES_MODEL="$MAIN_MODEL"

echo "   ✅ API Key 环境变量已导出"
echo "   ✅ Base URL 环境变量已设置"
echo "   ✅ API Server 环境变量已设置 (端口: 8642)"
echo "   ✅ HERMES_HOME=$HERMES_HOME"
echo "   ✅ HERMES_MODEL=$HERMES_MODEL (进程级模型覆盖)"

# ==================== 环境变量注入 ====================
echo "⚙️  注入环境变量到 .env..."
ENV_FILE="/data/.hermes/.env"
mkdir -p /data/.hermes

PERSISTENT_VARS=(
    "MODEL_PROVIDER" "MODEL_NAME" "HERMES_MODEL"
    "VISION_MODEL" "AUX_MODEL" "DELEGATION_MODEL"
    "XAI_API_KEY" "XAI_BASE_URL"
    "NVIDIA_API_KEY" "NVIDIA_BASE_URL"
    "SILICONFLOW_API_KEY" "SILICONFLOW_BASE_URL"
    "OPENAI_API_KEY"
    "ANTHROPIC_API_KEY"
    "GOOGLE_API_KEY" "GEMINI_API_KEY" "GEMINI_BASE_URL"
    "OPENROUTER_API_KEY" "OPENROUTER_BASE_URL"
    "LONGCAT_API_KEY" "LONGCAT_BASE_URL"
    "API_SERVER_ENABLED" "API_SERVER_PORT" "API_SERVER_HOST"
    "TELEGRAM_BOT_TOKEN" "TELEGRAM_ALLOWED_USERS" "TELEGRAM_PROXY"
    "DISCORD_BOT_TOKEN" "DISCORD_CLIENT_ID"
    "SLACK_BOT_TOKEN" "SLACK_APP_TOKEN" "SLACK_SIGNING_SECRET"
    "WHATSAPP_BUSINESS_ID" "WHATSAPP_PHONE_NUMBER" "WHATSAPP_ACCESS_TOKEN"
    "WEIXIN_ACCOUNT_ID" "WEIXIN_TOKEN" "WEIXIN_BASE_URL"
    "GATEWAY_ALLOW_ALL_USERS"
    "AUTH_TOKEN"
    "HF_TOKEN"
    "HF_DATASET_REPO"
)

# 合并策略：保留恢复的 .env 中由 BFF 等写入的变量（如 WEIXIN_ACCOUNT_ID/WEIXIN_TOKEN），
# 同时用进程环境变量覆盖同名键（进程环境变量优先级更高）。
# 这避免了 "先恢复再清空" 导致 BFF 写入的凭据丢失的问题。

# 第1步：读取恢复的 .env 中所有现有键值对（跳过注释和空行）
declare -A env_entries=()
if [ -f "$ENV_FILE" ]; then
    while IFS= read -r line; do
        # 跳过注释和空行
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        # 提取 KEY=VALUE
        eq_idx="${line%%=*}"
        if [ -n "$eq_idx" ] && [ "$eq_idx" != "$line" ]; then
            env_entries["$eq_idx"]="$line"
        fi
    done < "$ENV_FILE"
fi

# 第2步：用进程环境变量覆盖/新增 PERSISTENT_VARS 中的键
for var in "${PERSISTENT_VARS[@]}"; do
    if [ -n "${!var}" ]; then
        env_entries["$var"]="${var}=${!var}"
    else
        # 进程环境中没有该变量，但恢复的 .env 中可能有 → 保留恢复的值
        # 如果恢复的 .env 中也没有，则不写入
        :
    fi
done

# 第3步：写入合并后的 .env
{
    for key in "${!env_entries[@]}"; do
        echo "${env_entries[$key]}"
    done
} | sort > "$ENV_FILE"

RESTORED_COUNT=$(grep -c '=' "$ENV_FILE")
echo "   ✅ 已写入 ${RESTORED_COUNT} 个环境变量（含恢复的持久化变量）"

# ==================== 启动数据同步服务 ====================
SYNC_INTERVAL=${SYNC_INTERVAL:-30}
echo "🔄 数据同步间隔: ${SYNC_INTERVAL}秒（会话实时同步）"

echo "🔄 启动数据同步服务..."
python -m src.data_sync daemon &
SYNC_PID=$!
echo "   同步服务 PID: $SYNC_PID"

# ==================== 配置检查 + 模型锁定 ====================
echo "🔄 检查配置..."
hermes config check 2>/dev/null || echo "   配置检查完成"

echo "🔒 强制写入模型配置（防止 Hermes 启动时被覆盖）..."
hermes config set model.default "$MAIN_MODEL" 2>/dev/null || {
    echo "   ⚠️ hermes config set 不可用，使用直接写入方式"
    if command -v yq &>/dev/null; then
        yq -i ".model.default = \"$MAIN_MODEL\"" "$CONFIG_FILE"
    fi
}
hermes config set model.provider "$GATEWAY_MAIN_PROVIDER" 2>/dev/null || true
hermes config set model.base_url "$MAIN_BASE_URL" 2>/dev/null || true

# 验证 config.yaml 中模型是否正确
if command -v yq &>/dev/null; then
    ACTUAL_MODEL=$(yq '.model.default' "$CONFIG_FILE" 2>/dev/null)
    ACTUAL_PROVIDER=$(yq '.model.provider' "$CONFIG_FILE" 2>/dev/null)
    if [ "$ACTUAL_MODEL" != "$MAIN_MODEL" ]; then
        echo "   ⚠️ 模型被覆盖! 期望: $MAIN_MODEL, 实际: $ACTUAL_MODEL"
        echo "   🔄 重新写入模型配置..."
        yq -i ".model.default = \"$MAIN_MODEL\"" "$CONFIG_FILE"
        yq -i ".model.provider = \"$GATEWAY_MAIN_PROVIDER\"" "$CONFIG_FILE"
        yq -i ".model.base_url = \"$MAIN_BASE_URL\"" "$CONFIG_FILE"
    elif [ "$ACTUAL_PROVIDER" != "$GATEWAY_MAIN_PROVIDER" ]; then
        echo "   ⚠️ provider 被覆盖! 期望: $GATEWAY_MAIN_PROVIDER, 实际: $ACTUAL_PROVIDER"
        echo "   🔄 重新写入 provider 配置..."
        yq -i ".model.provider = \"$GATEWAY_MAIN_PROVIDER\"" "$CONFIG_FILE"
    fi
fi

echo "   ✅ 模型配置已锁定: $GATEWAY_MAIN_PROVIDER/$MAIN_MODEL"

# ==================== 启动 Gateway (API Server + 消息平台) ====================
echo "📡 启动 Hermes Gateway + API Server..."

# 启动前诊断：打印关键配置信息，便于排查 Provider authentication failed
MAIN_API_KEY_VAR="${PROVIDER_API_KEYS[$MAIN_PROVIDER]}"
MAIN_API_KEY_VAL="${!MAIN_API_KEY_VAR}"
echo "🔍 Gateway 配置诊断:"
echo "   原始 Provider: $MAIN_PROVIDER"
echo "   Gateway Provider: $GATEWAY_MAIN_PROVIDER"
echo "   Model: $MAIN_MODEL"
echo "   Base URL: $MAIN_BASE_URL"
if [ -n "$MAIN_API_KEY_VAL" ]; then
    echo "   API Key ($MAIN_API_KEY_VAR): 已设置 (长度: ${#MAIN_API_KEY_VAL})"
else
    echo "   ⚠️  API Key ($MAIN_API_KEY_VAR): 未设置! Provider authentication 可能失败"
fi

# 运行 hermes model 查看可用的 provider 列表（帮助诊断 Unknown provider 错误）
echo "📋 可用的 Provider 列表:"
hermes model 2>/dev/null | head -30 || echo "   ⚠️ 无法获取 provider 列表"

# 运行 hermes doctor 诊断配置问题
echo "🔧 运行配置诊断:"
hermes doctor 2>/dev/null | grep -E "(provider|model|config|error|warning)" | head -20 || echo "   ⚠️ hermes doctor 不可用"

# Gateway PID 文件（用于追踪当前运行的 gateway 进程）
GATEWAY_PIDFILE="/data/.hermes/gateway.pid"

# Gateway 包装器：自动重启 + 崩溃恢复
# 使用 --replace 避免端口冲突（BFF 偶尔也通过 hermes-cli.ts 调用 restartGateway）
# 崩溃后等待 30 秒重启；正常退出不重启
# BFF 保存 weixin 凭据后会调用 restartGateway()，该函数在 Docker 模式下
# 会 kill 旧进程然后 spawn "hermes gateway run"，与本包装器可能竞争。
# --replace 让 gateway 在检测到端口占用时自动替换旧进程，避免冲突。
(
    while true; do
        hermes gateway run --replace 2>&1 | while IFS= read -r line; do
            echo "$line"
            case "$line" in
                *"Gateway failed to connect"*)
                    echo "   ⚠️ 网关消息平台连接失败，API Server 仍可使用，30 秒后重试..."
                    ;;
            esac
        done
        EXIT_CODE=${PIPESTATUS[0]}
        if [ "$EXIT_CODE" -ne 0 ]; then
            echo "   ⚠️ 网关进程退出 (code=$EXIT_CODE)，30 秒后重启..."
            sleep 30
        else
            echo "   🛑 网关正常退出（可能被 BFF restartGateway 替换）"
            # 检查是否有新 gateway 进程在运行（BFF 可能已启动新进程）
            sleep 5
            if [ -f "$GATEWAY_PIDFILE" ]; then
                NEW_PID=$(python3 -c "import json; print(json.load(open('$GATEWAY_PIDFILE')).get('pid',0))" 2>/dev/null || echo 0)
                if [ "$NEW_PID" -gt 0 ] && kill -0 "$NEW_PID" 2>/dev/null; then
                    echo "   🔄 检测到新网关进程 (PID: $NEW_PID)，等待其退出..."
                    # 等待新进程退出后再继续循环
                    while kill -0 "$NEW_PID" 2>/dev/null; do sleep 5; done
                    echo "   ⚠️ 新网关进程已退出，30 秒后重启包装器..."
                    sleep 30
                    continue
                fi
            fi
            echo "   🛑 无新网关进程，不再重启"
            break
        fi
    done
) &
GATEWAY_PID=$!

# 等待 API Server 就绪
echo "   ⏳ 等待 API Server 就绪 (:8642)..."
API_READY=false
for i in $(seq 1 30); do
    if curl -sf http://127.0.0.1:8642/health > /dev/null 2>&1; then
        API_READY=true
        break
    fi
    sleep 1
done

if [ "$API_READY" = true ]; then
    echo "   ✅ API Server 已就绪 (http://127.0.0.1:8642)"
    # Gateway PID 文件由 Hermes 自己在 gateway run 启动时写入（gateway/run.py:write_pid_file）
    # 通过 symlink /home/appuser/.hermes → /data/.hermes，BFF GatewayManager 可正确读取
else
    echo "   ⚠️ API Server 未在 30 秒内就绪，继续启动 Web UI（API Server 可能稍后可用）"
fi

if kill -0 $GATEWAY_PID 2>/dev/null; then
    echo "   ✅ 网关进程运行中 (PID: $GATEWAY_PID)"
else
    echo "   ⚠️ 网关进程已退出，仅 Web UI 可用"
fi

echo ""
echo "💡 提示："
echo "   - Channels 页面可配置微信/飞书/企业微信等平台"
echo "   - Models 页面可管理模型供应商"
echo "   - Jobs 页面可管理定时任务"
echo ""

# ==================== Auth Token 处理 ====================
echo "🔑 配置 Web UI 认证..."
if [ -z "$AUTH_TOKEN" ]; then
    # 尝试从持久化文件恢复
    AUTH_TOKEN_FILE="/data/.hermes-web-ui/.token"
    if [ -f "$AUTH_TOKEN_FILE" ]; then
        AUTH_TOKEN=$(cat "$AUTH_TOKEN_FILE")
        echo "   ✅ 已恢复 Web UI 认证 Token"
    else
        # 自动生成新 Token
        AUTH_TOKEN=$(openssl rand -hex 16 2>/dev/null || head -c 32 /dev/urandom | xxd -p | head -c 32)
        mkdir -p /data/.hermes-web-ui
        echo "$AUTH_TOKEN" > "$AUTH_TOKEN_FILE"
        echo ""
        echo "   ╔══════════════════════════════════════════════════╗"
        echo "   ║  🔑 Web UI 认证 Token (请保存！)                 ║"
        echo "   ║  $AUTH_TOKEN"
        echo "   ║                                                    ║"
        echo "   ║  在 Web UI 登录页面输入此 Token                    ║"
        echo "   ║  也可在 HF Spaces Settings 设置 AUTH_TOKEN 覆盖   ║"
        echo "   ╚══════════════════════════════════════════════════╝"
        echo ""
    fi
else
    echo "   ✅ 使用环境变量中的 AUTH_TOKEN"
fi
export AUTH_TOKEN

# ==================== 修复 hermes-web-ui v0.5.30+ agent bridge ====================
# v0.5.30 后通信架构切换为 Unix socket IPC，bridge 启动需要额外依赖
echo "🔧 修复 agent bridge..."

# 1. 确保 bridge 脚本有执行权限（修复 exit code 126）
# Dockerfile 将 hermes-web-ui 安装到 /opt/hermes-web-ui，同时兼容标准 npm 全局路径
BRIDGE_PATHS=(
    "/opt/hermes-web-ui/dist/server/agent-bridge/hermes_bridge.py"
    "/usr/lib/node_modules/hermes-web-ui/dist/server/agent-bridge/hermes_bridge.py"
)
BRIDGE_FOUND=false
BRIDGE_SCRIPT=""
for bridge_path in "${BRIDGE_PATHS[@]}"; do
    if [ -f "$bridge_path" ]; then
        chmod +x "$bridge_path"
        echo "   ✅ bridge 脚本权限已修复: $bridge_path"
        BRIDGE_FOUND=true
        BRIDGE_SCRIPT="$bridge_path"
        break
    fi
done
if [ "$BRIDGE_FOUND" = false ]; then
    echo "   ⚠️ 未在常用路径找到 bridge 脚本，尝试全局搜索..."
    find /opt /usr -name "hermes_bridge.py" -type f 2>/dev/null | while read -r f; do
        chmod +x "$f"
        echo "   ✅ 已设置权限: $f"
        BRIDGE_SCRIPT="$f"
        BRIDGE_FOUND=true
        break
    done
fi

# 2. 确保 hermes 模块可被 bridge 加载（修复 exit code 1）
# bridge 脚本需要从 ~/.hermes/hermes-agent 导入模块
# 使用多种方法动态查找 hermes 包的实际安装路径

echo "🔍 查找 hermes 包路径..."

HERMES_PKG_PATH=""

# 优先方法：若保留的 hermes-agent 源码目录存在，直接作为模块根目录（支持最新的 run_agent.py 桥接模式）
if [ -d "/usr/local/lib/hermes-agent" ]; then
    HERMES_PKG_PATH="/usr/local/lib/hermes-agent"
    echo "   ✅ 优先使用保留的 hermes-agent 源码包: $HERMES_PKG_PATH"
fi

# 方法1: 直接搜索 site-packages 目录（最可靠）
if [ -z "$HERMES_PKG_PATH" ]; then
    for candidate in $(find /usr/local/lib/python*/site-packages -maxdepth 1 -type d \( -name "hermes" -o -name "hermes_agent" -o -name "hermes_cli" \) 2>/dev/null); do
        if [ -f "$candidate/__init__.py" ]; then
            HERMES_PKG_PATH="$candidate"
            echo "   ✅ 方法1找到 hermes 包: $HERMES_PKG_PATH"
            break
        fi
    done
fi

# 方法2: 使用 pip show 获取安装位置
if [ -z "$HERMES_PKG_PATH" ]; then
    PIP_LOCATION=$(python3 -m pip show hermes-agent 2>/dev/null | grep ^Location | cut -d' ' -f2-)
    if [ -n "$PIP_LOCATION" ]; then
        for name in hermes hermes_agent hermes_cli; do
            if [ -d "$PIP_LOCATION/$name" ] && [ -f "$PIP_LOCATION/$name/__init__.py" ]; then
                HERMES_PKG_PATH="$PIP_LOCATION/$name"
                echo "   ✅ 方法2找到 hermes 包: $HERMES_PKG_PATH"
                break
            fi
        done
    fi
fi

# 方法3: 通过 hermes 命令脚本反推包路径
if [ -z "$HERMES_PKG_PATH" ]; then
    HERMES_CMD=$(which hermes 2>/dev/null)
    if [ -n "$HERMES_CMD" ]; then
        # hermes 命令通常是 setuptools 生成的 wrapper 脚本
        # 尝试从中提取 import 的模块名
        HERMES_MODULE=$(head -50 "$HERMES_CMD" 2>/dev/null | grep -E "from|import" | grep -oE "hermes[a-z_]*" | head -1)
        if [ -n "$HERMES_MODULE" ]; then
            HERMES_TRY=$(python3 -c "import $HERMES_MODULE; print($HERMES_MODULE.__path__[0])" 2>/dev/null)
            if [ -n "$HERMES_TRY" ]; then
                HERMES_PKG_PATH="$HERMES_TRY"
                echo "   ✅ 方法3找到 hermes 包: $HERMES_PKG_PATH (模块: $HERMES_MODULE)"
            fi
        fi
    fi
fi

# 方法4: 遍历 sys.path 查找
if [ -z "$HERMES_PKG_PATH" ]; then
    HERMES_PKG_PATH=$(python3 -c "
import sys, os
for p in sys.path:
    for name in ['hermes', 'hermes_agent', 'hermes_cli']:
        candidate = os.path.join(p, name)
        if os.path.isdir(candidate) and os.path.exists(os.path.join(candidate, '__init__.py')):
            print(candidate)
            sys.exit(0)
print('')
" 2>/dev/null)
    if [ -n "$HERMES_PKG_PATH" ]; then
        echo "   ✅ 方法4找到 hermes 包: $HERMES_PKG_PATH"
    fi
fi

# 方法5: 如果 /usr/local/lib/hermes-agent 存在（webuibug.txt 提到的情况）
if [ -z "$HERMES_PKG_PATH" ] && [ -d "/usr/local/lib/hermes-agent" ]; then
    HERMES_PKG_PATH="/usr/local/lib/hermes-agent"
    echo "   ✅ 方法5找到 hermes 包: $HERMES_PKG_PATH"
fi

# ~/.hermes 可能是指向 /data/.hermes 的 symlink，确保目标目录存在
HERMES_REAL_HOME=$(realpath ~/.hermes 2>/dev/null || echo "$HOME/.hermes")
mkdir -p "$HERMES_REAL_HOME"

if [ -n "$HERMES_PKG_PATH" ] && [ -d "$HERMES_PKG_PATH" ]; then
    # 创建 hermes-agent 链接（bridge 脚本期望的路径）
    if [ ! -e "$HERMES_REAL_HOME/hermes-agent" ] && [ ! -L "$HERMES_REAL_HOME/hermes-agent" ]; then
        ln -s "$HERMES_PKG_PATH" "$HERMES_REAL_HOME/hermes-agent"
        echo "   ✅ hermes-agent 模块链接已创建 → $HERMES_PKG_PATH"
    fi
    # 同时创建 hermes 链接（以防 import 的是 hermes）
    if [ ! -e "$HERMES_REAL_HOME/hermes" ] && [ ! -L "$HERMES_REAL_HOME/hermes" ]; then
        ln -s "$HERMES_PKG_PATH" "$HERMES_REAL_HOME/hermes"
        echo "   ✅ hermes 模块链接已创建 → $HERMES_PKG_PATH"
    fi
    
    # 设置 PYTHONPATH，确保 bridge 脚本能找到 hermes 包
    PYTHON_SITE_PACKAGES=$(python3 -c "import site; print(site.getsitepackages()[0])" 2>/dev/null)
    if [ -n "$PYTHON_SITE_PACKAGES" ]; then
        export PYTHONPATH="${PYTHONPATH:+$PYTHONPATH:}$PYTHON_SITE_PACKAGES"
        echo "   ✅ PYTHONPATH 已设置: $PYTHONPATH"
    fi
    
    # 诊断：尝试运行 bridge 脚本查看具体错误
    echo "🔍 测试 bridge 脚本..."
    if [ -f "$BRIDGE_SCRIPT" ]; then
        python3 "$BRIDGE_SCRIPT" --help 2>&1 | head -5 || echo "   ⚠️ bridge 脚本测试失败"
    fi
else
    echo "   ❌ 所有方法都无法找到 hermes 包路径!"
    echo "   📋 诊断信息:"
    echo "      Python site-packages:"
    python3 -c "import site; [print('     ', p) for p in site.getsitepackages()]" 2>/dev/null || true
    echo "      sys.path:"
    python3 -c "import sys; [print('     ', p) for p in sys.path if __import__('os').path.isdir(p)]" 2>/dev/null || true
    echo "      pip list | grep hermes:"
    python3 -m pip list 2>/dev/null | grep -i hermes || echo "        (无结果)"
    echo "      which hermes: $(which hermes 2>/dev/null || echo '未找到')"
fi

# ==================== 启动 Web UI (BFF Server) ====================
echo "🌐 启动 Hermes Web UI..."
echo "   BFF Server: http://0.0.0.0:7860"
echo "   Upstream:   http://127.0.0.1:8642"
echo ""

# 确保运行时环境变量设置完毕
export PORT=7860
export UPSTREAM=http://127.0.0.1:8642
export HERMES_BIN=/usr/local/bin/hermes
export HERMES_HOME=/data/.hermes

# 优雅关闭
cleanup() {
    echo ""
    echo "🛑 执行清理..."

    # 备份数据
    if [ -n "$HF_DATASET_REPO" ]; then
        echo "   💾 执行最终数据备份..."
        python -m src.data_sync backup --force 2>/dev/null || echo "   ⚠️ 备份失败"
    fi

    # 停止各进程（顺序：BFF → Gateway → Sync）
    if [ -n "$BFF_PID" ] && kill -0 $BFF_PID 2>/dev/null; then
        echo "   🛑 停止 Web UI..."
        kill $BFF_PID 2>/dev/null || true
        wait $BFF_PID 2>/dev/null || true
    fi
    if [ -n "$GATEWAY_PID" ] && kill -0 $GATEWAY_PID 2>/dev/null; then
        echo "   🛑 停止 Gateway..."
        kill $GATEWAY_PID 2>/dev/null || true
        wait $GATEWAY_PID 2>/dev/null || true
    fi
    if kill -0 $SYNC_PID 2>/dev/null; then
        echo "   🛑 停止数据同步..."
        kill $SYNC_PID 2>/dev/null || true
        wait $SYNC_PID 2>/dev/null || true
    fi

    echo "👋 再见！"
    exit 0
}

trap cleanup SIGTERM SIGINT

# 启动 BFF Server (替代 hermes dashboard，内部端口 7861)
PORT=7861 node /opt/hermes-web-ui/dist/server/index.js &
BFF_PID=$!

# 等待 BFF 就绪
echo "   ⏳ 等待 Web UI 就绪..."
BFF_READY=false
for i in $(seq 1 20); do
    if curl -sf http://localhost:7861/health > /dev/null 2>&1; then
        BFF_READY=true
        break
    fi
    sleep 1
done

if [ "$BFF_READY" = true ]; then
    echo "   ✅ Web UI 已就绪 → http://localhost:7861"
else
    echo "   ⚠️ Web UI 未在 20 秒内就绪，请查看日志"
fi

# 启动 Image Proxy (对外端口 7860, HF Spaces 入口)
echo "🖼️  启动 Image Proxy..."
BFF_PORT=7861 LISTEN_PORT=7860 IMAGE_DIR=/data/.hermes/image_cache \
    node /app/image-proxy.js &
PROXY_PID=$!

# 等待 Image Proxy 就绪
PROXY_READY=false
for i in $(seq 1 10); do
    if curl -sf http://localhost:7860/health > /dev/null 2>&1; then
        PROXY_READY=true
        break
    fi
    sleep 1
done

if [ "$PROXY_READY" = true ]; then
    echo "   ✅ Media Proxy 已就绪 → http://localhost:7860/files/"
else
    echo "   ⚠️ Image Proxy 未就绪，但继续运行"
fi

# 再次验证模型配置（BFF 启动可能修改 config.yaml）
if [ -f "$CONFIG_FILE" ]; then
    if command -v yq &>/dev/null; then
        ACTUAL_MODEL=$(yq '.model.default' "$CONFIG_FILE" 2>/dev/null)
        if [ -n "$ACTUAL_MODEL" ] && [ "$ACTUAL_MODEL" != "$MAIN_MODEL" ] && [ "$ACTUAL_MODEL" != "null" ]; then
            echo "   ⚠️ 检测到模型被 BFF 启动流程覆盖!"
            echo "   📋 期望: $MAIN_MODEL, 实际: $ACTUAL_MODEL"
            echo "   🔒 重新写入正确的模型配置..."
            yq -i ".model.default = \"$MAIN_MODEL\"" "$CONFIG_FILE"
            yq -i ".model.provider = \"$GATEWAY_MAIN_PROVIDER\"" "$CONFIG_FILE"
            yq -i ".model.base_url = \"$MAIN_BASE_URL\"" "$CONFIG_FILE"
            echo "   ✅ 模型已修正: $GATEWAY_MAIN_PROVIDER/$MAIN_MODEL"
        elif [ -z "$ACTUAL_MODEL" ] || [ "$ACTUAL_MODEL" = "null" ]; then
            echo "   ⚠️ 检测到模型字段为空! 重新写入..."
            yq -i ".model.default = \"$MAIN_MODEL\"" "$CONFIG_FILE"
            yq -i ".model.provider = \"$GATEWAY_MAIN_PROVIDER\"" "$CONFIG_FILE"
            yq -i ".model.base_url = \"$MAIN_BASE_URL\"" "$CONFIG_FILE"
            echo "   ✅ 模型已修正: $GATEWAY_MAIN_PROVIDER/$MAIN_MODEL"
        else
            echo "   ✅ 模型配置验证通过: $GATEWAY_MAIN_PROVIDER/$MAIN_MODEL"
        fi
    fi
fi

# 等待 BFF 主进程（前台阻塞，容器生命周期由 BFF 控制）
wait $BFF_PID
