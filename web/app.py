#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Transit Panel - Web Management Interface
Flask-based web panel for managing sing-box transit nodes
"""

import os
import json
import subprocess
import hashlib
import secrets
from datetime import datetime, timedelta
from functools import wraps

from flask import Flask, render_template, request, jsonify, redirect, url_for, session

# ==================== 配置 ====================
CONFIG_DIR = os.environ.get('CONFIG_DIR', '/etc/transit-panel')
DATA_DIR = os.environ.get('DATA_DIR', '/var/lib/transit-panel')
LOG_DIR = os.environ.get('LOG_DIR', '/var/log/transit-panel')
SINGBOX_BIN = os.environ.get('SINGBOX_BIN', '/usr/local/bin/sing-box')

app = Flask(__name__)

# ==================== Session 配置 ====================
# 使用文件存储 session，解决 gunicorn 多进程不共享问题
SESSION_DIR = os.path.join(DATA_DIR, 'sessions')
os.makedirs(SESSION_DIR, exist_ok=True)

# 持久化 secret key
SECRET_KEY_FILE = os.path.join(DATA_DIR, '.secret_key')
def get_secret_key():
    if os.path.exists(SECRET_KEY_FILE):
        with open(SECRET_KEY_FILE, 'r') as f:
            return f.read().strip()
    else:
        key = secrets.token_hex(32)
        os.makedirs(DATA_DIR, exist_ok=True)
        with open(SECRET_KEY_FILE, 'w') as f:
            f.write(key)
        os.chmod(SECRET_KEY_FILE, 0o600)
        return key

app.secret_key = get_secret_key()
app.permanent_session_lifetime = timedelta(days=7)

# Cookie 配置
app.config.update(
    SESSION_COOKIE_SECURE=False,
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE='Lax',
    SESSION_COOKIE_NAME='transit_session'
)

# 简单的文件 session 存储
class FileSession:
    def __init__(self, session_dir):
        self.session_dir = session_dir
    
    def get(self, session_id):
        path = os.path.join(self.session_dir, session_id)
        if os.path.exists(path):
            try:
                with open(path, 'r') as f:
                    data = json.load(f)
                # 检查过期
                if data.get('expires', 0) > datetime.now().timestamp():
                    return data.get('data', {})
            except:
                pass
        return {}
    
    def save(self, session_id, data, expires_days=7):
        path = os.path.join(self.session_dir, session_id)
        expires = (datetime.now() + timedelta(days=expires_days)).timestamp()
        with open(path, 'w') as f:
            json.dump({'data': data, 'expires': expires}, f)
    
    def delete(self, session_id):
        path = os.path.join(self.session_dir, session_id)
        if os.path.exists(path):
            os.remove(path)

file_session = FileSession(SESSION_DIR)

# ==================== 工具函数 ====================
def load_config():
    """加载面板配置"""
    config_file = os.path.join(CONFIG_DIR, 'config.json')
    try:
        with open(config_file, 'r') as f:
            return json.load(f)
    except:
        return {"panel": {}, "inbounds": [], "outbounds": [], "routes": []}

def save_config(config):
    """保存面板配置"""
    config_file = os.path.join(CONFIG_DIR, 'config.json')
    with open(config_file, 'w') as f:
        json.dump(config, f, indent=2, ensure_ascii=False)

def load_singbox_config():
    """加载 sing-box 配置"""
    config_file = os.path.join(CONFIG_DIR, 'singbox.json')
    try:
        with open(config_file, 'r') as f:
            return json.load(f)
    except:
        return {"log": {}, "inbounds": [], "outbounds": [], "route": {"rules": []}}

def save_singbox_config(config):
    """保存 sing-box 配置"""
    config_file = os.path.join(CONFIG_DIR, 'singbox.json')
    with open(config_file, 'w') as f:
        json.dump(config, f, indent=2, ensure_ascii=False)

def hash_password(password):
    """密码哈希"""
    return hashlib.sha256(password.encode()).hexdigest()

def generate_password(length=16):
    """生成随机密码"""
    import base64
    return base64.b64encode(secrets.token_bytes(length)).decode()[:length]

def generate_uuid():
    """生成 UUID"""
    import uuid
    return str(uuid.uuid4())

def get_public_ip():
    """获取公网 IP"""
    import urllib.request
    try:
        return urllib.request.urlopen('https://api.ipify.org', timeout=5).read().decode()
    except:
        return "127.0.0.1"

def get_service_status():
    """获取服务状态"""
    try:
        result = subprocess.run(['systemctl', 'is-active', 'transit-panel'], 
                              capture_output=True, text=True)
        return result.stdout.strip() == 'active'
    except:
        return False

def restart_service():
    """重启服务"""
    try:
        subprocess.run(['systemctl', 'restart', 'transit-panel'], check=True)
        return True
    except:
        return False

def generate_cert(name, cert_dir):
    """生成自签名证书"""
    cert_path = os.path.join(cert_dir, f'{name}.crt')
    key_path = os.path.join(cert_dir, f'{name}.key')
    
    os.makedirs(cert_dir, exist_ok=True)
    
    subprocess.run([
        'openssl', 'req', '-x509', '-nodes', '-newkey', 'ec',
        '-pkeyopt', 'ec_paramgen_curve:prime256v1',
        '-keyout', key_path, '-out', cert_path,
        '-subj', '/CN=bing.com', '-days', '36500'
    ], capture_output=True)
    
    os.chmod(key_path, 0o600)
    return cert_path, key_path

def generate_reality_keypair():
    """生成 Reality 密钥对"""
    try:
        result = subprocess.run([SINGBOX_BIN, 'generate', 'reality-keypair'],
                              capture_output=True, text=True)
        lines = result.stdout.strip().split('\n')
        private_key = ''
        public_key = ''
        for line in lines:
            if 'PrivateKey' in line:
                private_key = line.split()[-1]
            elif 'PublicKey' in line:
                public_key = line.split()[-1]
        return private_key, public_key
    except:
        return '', ''

# ==================== 认证装饰器 ====================
def login_required(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if 'logged_in' not in session:
            if request.is_json:
                return jsonify({'success': False, 'error': '未登录'}), 401
            return redirect(url_for('login'))
        return f(*args, **kwargs)
    return decorated_function

# ==================== 页面路由 ====================
@app.route('/')
def index():
    if 'logged_in' in session:
        return redirect(url_for('dashboard'))
    return redirect(url_for('login'))

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        data = request.get_json() if request.is_json else request.form
        username = data.get('username', '')
        password = data.get('password', '')
        
        config = load_config()
        panel_config = config.get('panel', {})
        
        if (username == panel_config.get('admin_user', 'admin') and 
            hash_password(password) == panel_config.get('admin_pass_hash', '')):
            session.permanent = True
            session['logged_in'] = True
            session['username'] = username
            
            if request.is_json:
                return jsonify({'success': True})
            return redirect(url_for('dashboard'))
        
        if request.is_json:
            return jsonify({'success': False, 'error': '用户名或密码错误'}), 401
        return render_template('login.html', error='用户名或密码错误')
    
    return render_template('login.html')

@app.route('/logout')
def logout():
    session.clear()
    return redirect(url_for('login'))

@app.route('/dashboard')
@login_required
def dashboard():
    config = load_config()
    return render_template('dashboard.html',
                         service_running=get_service_status(),
                         inbound_count=len(config.get('inbounds', [])),
                         outbound_count=len(config.get('outbounds', [])),
                         route_count=len(config.get('routes', [])),
                         server_ip=config.get('panel', {}).get('server_ip', ''))

@app.route('/inbounds')
@login_required
def inbounds():
    config = load_config()
    return render_template('inbounds.html', inbounds=config.get('inbounds', []))

@app.route('/outbounds')
@login_required
def outbounds():
    config = load_config()
    return render_template('outbounds.html', outbounds=config.get('outbounds', []))

@app.route('/routes')
@login_required
def routes():
    config = load_config()
    return render_template('routes.html', 
                         routes=config.get('routes', []),
                         inbounds=config.get('inbounds', []),
                         outbounds=config.get('outbounds', []))

@app.route('/settings')
@login_required
def settings():
    return render_template('settings.html', service_running=get_service_status())

# ==================== API 路由 ====================

# --- 系统 API ---
@app.route('/api/status')
@login_required
def api_status():
    config = load_config()
    return jsonify({
        'success': True,
        'data': {
            'service_running': get_service_status(),
            'inbound_count': len(config.get('inbounds', [])),
            'outbound_count': len(config.get('outbounds', [])),
            'route_count': len(config.get('routes', [])),
            'server_ip': config.get('panel', {}).get('server_ip', '')
        }
    })

@app.route('/api/system')
@login_required
def api_system():
    """获取系统资源状态"""
    def format_bytes(bytes_val):
        for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
            if bytes_val < 1024:
                return f'{bytes_val:.1f} {unit}'
            bytes_val /= 1024
        return f'{bytes_val:.1f} PB'
    
    try:
        # CPU 使用率
        cpu_percent = 0
        try:
            with open('/proc/stat', 'r') as f:
                line = f.readline()
                parts = line.split()
                if len(parts) >= 5:
                    idle = int(parts[4])
                    total = sum(int(x) for x in parts[1:])
                    cpu_percent = (1 - idle / total) * 100 if total > 0 else 0
        except:
            cpu_percent = 0
        
        # 内存使用
        ram_total = ram_used = ram_percent = 0
        try:
            with open('/proc/meminfo', 'r') as f:
                meminfo = {}
                for line in f:
                    parts = line.split()
                    if len(parts) >= 2:
                        meminfo[parts[0].rstrip(':')] = int(parts[1]) * 1024
                ram_total = meminfo.get('MemTotal', 0)
                ram_free = meminfo.get('MemAvailable', meminfo.get('MemFree', 0))
                ram_used = ram_total - ram_free
                ram_percent = (ram_used / ram_total * 100) if ram_total > 0 else 0
        except:
            pass
        
        # 硬盘使用
        disk_total = disk_used = disk_percent = 0
        try:
            result = subprocess.run(['df', '-B1', '/'], capture_output=True, text=True)
            lines = result.stdout.strip().split('\n')
            if len(lines) >= 2:
                parts = lines[1].split()
                if len(parts) >= 5:
                    disk_total = int(parts[1])
                    disk_used = int(parts[2])
                    disk_percent = float(parts[4].rstrip('%'))
        except:
            pass
        
        # 网络流量
        net_sent = net_recv = 0
        try:
            with open('/proc/net/dev', 'r') as f:
                for line in f.readlines()[2:]:
                    parts = line.split()
                    if len(parts) >= 10:
                        iface = parts[0].rstrip(':')
                        if iface not in ['lo']:
                            net_recv += int(parts[1])
                            net_sent += int(parts[9])
        except:
            pass
        
        return jsonify({
            'success': True,
            'data': {
                'cpu': round(cpu_percent, 1),
                'ram_total': format_bytes(ram_total),
                'ram_used': format_bytes(ram_used),
                'ram_percent': round(ram_percent, 1),
                'disk_total': format_bytes(disk_total),
                'disk_used': format_bytes(disk_used),
                'disk_percent': round(disk_percent, 1),
                'net_sent': format_bytes(net_sent),
                'net_recv': format_bytes(net_recv)
            }
        })
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/service/<action>', methods=['POST'])
@login_required
def api_service(action):
    try:
        if action == 'start':
            subprocess.run(['systemctl', 'start', 'transit-panel'], check=True)
        elif action == 'stop':
            subprocess.run(['systemctl', 'stop', 'transit-panel'], check=True)
        elif action == 'restart':
            subprocess.run(['systemctl', 'restart', 'transit-panel'], check=True)
        else:
            return jsonify({'success': False, 'error': '无效操作'})
        return jsonify({'success': True})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/logs')
@login_required
def api_logs():
    log_file = os.path.join(LOG_DIR, 'singbox.log')
    try:
        with open(log_file, 'r') as f:
            lines = f.readlines()[-100:]
        return jsonify({'success': True, 'data': ''.join(lines)})
    except:
        return jsonify({'success': True, 'data': '暂无日志'})

# --- 入站 API ---
@app.route('/api/inbounds')
@login_required
def api_inbounds():
    config = load_config()
    return jsonify({'success': True, 'data': config.get('inbounds', [])})

@app.route('/api/inbounds', methods=['POST'])
@login_required
def api_add_inbound():
    data = request.get_json()
    protocol = data.get('type')
    
    config = load_config()
    singbox_config = load_singbox_config()
    server_ip = config.get('panel', {}).get('server_ip', get_public_ip())
    cert_dir = os.path.join(CONFIG_DIR, 'certs')
    
    tag = data.get('tag') or f'{protocol}-in'
    
    # 随机端口 10000-60000
    port_str = data.get('port', '')
    if port_str and str(port_str).strip():
        port = int(port_str)
    else:
        import random
        port = random.randint(10000, 60000)
    
    # 检查标签是否已存在
    for inbound in config.get('inbounds', []):
        if inbound.get('tag') == tag:
            return jsonify({'success': False, 'error': f'标签 {tag} 已存在'})
    
    panel_inbound = {
        'type': protocol,
        'tag': tag,
        'port': port,
        'created_at': datetime.now().isoformat()
    }
    
    singbox_inbound = {
        'type': protocol if protocol != 'vless-reality' else 'vless',
        'tag': tag,
        'listen': '::',
        'listen_port': port
    }
    
    share_link = ''
    
    if protocol == 'hysteria2':
        password = data.get('password') or generate_password()
        masquerade = data.get('masquerade', 'www.bing.com')
        cert_path, key_path = generate_cert(f'hy2-{tag}', cert_dir)
        
        panel_inbound.update({
            'password': password,
            'masquerade': masquerade
        })
        
        singbox_inbound.update({
            'users': [{'password': password}],
            'masquerade': f'https://{masquerade}',
            'tls': {
                'enabled': True,
                'certificate_path': cert_path,
                'key_path': key_path
            }
        })
        
        share_link = f'hy2://{password}@{server_ip}:{port}?insecure=1&sni={masquerade}#{tag}'
        
    elif protocol == 'tuic':
        uuid = data.get('uuid') or generate_uuid()
        password = data.get('password') or generate_password()
        cert_path, key_path = generate_cert(f'tuic-{tag}', cert_dir)
        
        panel_inbound.update({
            'uuid': uuid,
            'password': password
        })
        
        singbox_inbound.update({
            'users': [{'uuid': uuid, 'password': password}],
            'congestion_control': 'bbr',
            'zero_rtt_handshake': False,
            'tls': {
                'enabled': True,
                'alpn': ['h3'],
                'certificate_path': cert_path,
                'key_path': key_path
            }
        })
        
        share_link = f'tuic://{uuid}:{password}@{server_ip}:{port}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#{tag}'
        
    elif protocol == 'vless-reality':
        uuid = data.get('uuid') or generate_uuid()
        server_name = data.get('server_name', 'icloud.com')  # 默认 icloud.com
        private_key, public_key = generate_reality_keypair()
        short_id = secrets.token_hex(8)
        fingerprint = 'firefox'  # 指纹
        spider_x = '/'  # SpiderX
        
        panel_inbound.update({
            'uuid': uuid,
            'server_name': server_name,
            'public_key': public_key,
            'short_id': short_id,
            'fingerprint': fingerprint
        })
        
        singbox_inbound.update({
            'users': [{'uuid': uuid, 'flow': 'xtls-rprx-vision'}],
            'tls': {
                'enabled': True,
                'server_name': server_name,
                'reality': {
                    'enabled': True,
                    'handshake': {'server': server_name, 'server_port': 443},
                    'private_key': private_key,
                    'short_id': [short_id]
                }
            }
        })
        
        # 分享链接包含 fingerprint 和 spiderX
        share_link = f'vless://{uuid}@{server_ip}:{port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni={server_name}&fp={fingerprint}&pbk={public_key}&sid={short_id}&spx={spider_x}&type=tcp&headerType=none#{tag}'
    
    panel_inbound['share_link'] = share_link
    
    config.setdefault('inbounds', []).append(panel_inbound)
    singbox_config.setdefault('inbounds', []).append(singbox_inbound)
    
    save_config(config)
    save_singbox_config(singbox_config)
    restart_service()
    
    return jsonify({'success': True, 'data': panel_inbound})

@app.route('/api/inbounds/<tag>', methods=['DELETE'])
@login_required
def api_delete_inbound(tag):
    config = load_config()
    singbox_config = load_singbox_config()
    
    config['inbounds'] = [i for i in config.get('inbounds', []) if i.get('tag') != tag]
    singbox_config['inbounds'] = [i for i in singbox_config.get('inbounds', []) if i.get('tag') != tag]
    
    save_config(config)
    save_singbox_config(singbox_config)
    restart_service()
    
    return jsonify({'success': True})

@app.route('/api/inbounds/<tag>', methods=['PUT'])
@login_required
def api_edit_inbound(tag):
    """编辑入站配置 - 支持标签修改、流量限制和截止日期"""
    data = request.get_json()
    config = load_config()
    singbox_config = load_singbox_config()
    
    # 查找入站
    inbound_idx = None
    for i, inbound in enumerate(config.get('inbounds', [])):
        if inbound.get('tag') == tag:
            inbound_idx = i
            break
    
    if inbound_idx is None:
        return jsonify({'success': False, 'error': f'入站 {tag} 不存在'})
    
    inbound = config['inbounds'][inbound_idx]
    new_tag = data.get('new_tag', tag)
    
    # 如果标签改变，需要更新多处
    if new_tag != tag:
        # 更新 config.json 中的 tag
        inbound['tag'] = new_tag
        
        # 更新 singbox.json 中的 tag
        for sb_inbound in singbox_config.get('inbounds', []):
            if sb_inbound.get('tag') == tag:
                sb_inbound['tag'] = new_tag
                break
        
        # 更新路由规则中的引用
        for rule in singbox_config.get('route', {}).get('rules', []):
            if tag in rule.get('inbound', []):
                rule['inbound'] = [new_tag if x == tag else x for x in rule['inbound']]
        
        # 更新面板config中的路由
        for route in config.get('routes', []):
            if route.get('inbound') == tag:
                route['inbound'] = new_tag
        
        # 重新生成分享链接
        server_ip = config.get('panel', {}).get('server_ip', get_public_ip())
        port = inbound.get('port')
        protocol = inbound.get('type')
        
        if protocol == 'hysteria2':
            password = inbound.get('password', '')
            inbound['share_link'] = f'hy2://{password}@{server_ip}:{port}?insecure=1#{new_tag}'
        elif protocol == 'tuic':
            uuid = inbound.get('uuid', '')
            password = inbound.get('password', '')
            inbound['share_link'] = f'tuic://{uuid}:{password}@{server_ip}:{port}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#{new_tag}'
        elif protocol == 'vless-reality':
            uuid = inbound.get('uuid', '')
            server_name = inbound.get('server_name', 'icloud.com')
            public_key = inbound.get('public_key', '')
            short_id = inbound.get('short_id', '')
            inbound['share_link'] = f'vless://{uuid}@{server_ip}:{port}?type=tcp&security=reality&pbk={public_key}&fp=firefox&sni={server_name}&sid={short_id}&flow=xtls-rprx-vision#{new_tag}'
    
    # 更新其他字段
    if 'traffic_limit' in data:
        inbound['traffic_limit'] = data['traffic_limit']  # GB
    if 'expire_date' in data:
        inbound['expire_date'] = data['expire_date']  # YYYY-MM-DD
    if 'remark' in data:
        inbound['remark'] = data['remark']
    
    save_config(config)
    if new_tag != tag:
        save_singbox_config(singbox_config)
        restart_service()
    
    return jsonify({'success': True, 'data': inbound})

# --- 出站 API ---
@app.route('/api/outbounds')
@login_required
def api_outbounds():
    config = load_config()
    return jsonify({'success': True, 'data': config.get('outbounds', [])})

def parse_proxy_link(link):
    """解析代理链接 - 支持多种格式"""
    import base64
    import urllib.parse
    import re
    
    link = link.strip()
    if not link:
        return None
    
    # VLESS: vless://uuid@server:port?params#name
    if link.startswith('vless://'):
        try:
            match = link[8:]
            if '@' not in match:
                return None
            uuid_part, rest = match.split('@', 1)
            
            # 处理 server:port 部分
            if '?' in rest:
                server_port, params = rest.split('?', 1)
            elif '#' in rest:
                server_port, params = rest.split('#', 1)
                params = '#' + params
            else:
                server_port, params = rest, ''
            
            if ':' in server_port:
                server, port = server_port.rsplit(':', 1)
                port = re.sub(r'[^\d]', '', port)  # 移除非数字
            else:
                server, port = server_port, '443'
            
            name = urllib.parse.unquote(params.split('#')[-1]) if '#' in params else 'vless'
            
            return {
                'type': 'vless',
                'tag': name,
                'server': server,
                'server_port': int(port) if port else 443,
                'uuid': uuid_part
            }
        except Exception as e:
            print(f"VLESS 解析失败: {e}")
            return None
    
    # VMess: vmess://base64...
    elif link.startswith('vmess://'):
        try:
            b64_str = link[8:]
            # 添加 padding
            padding = 4 - len(b64_str) % 4
            if padding != 4:
                b64_str += '=' * padding
            decoded = base64.b64decode(b64_str).decode('utf-8')
            data = json.loads(decoded)
            return {
                'type': 'vmess',
                'tag': data.get('ps', 'vmess'),
                'server': data.get('add', ''),
                'server_port': int(data.get('port', 443)),
                'uuid': data.get('id', ''),
                'alter_id': int(data.get('aid', 0))
            }
        except Exception as e:
            print(f"VMess 解析失败: {e}")
            return None
    
    # Trojan: trojan://password@server:port?params#name
    elif link.startswith('trojan://'):
        try:
            match = link[9:]
            if '@' not in match:
                return None
            password, rest = match.split('@', 1)
            
            server_port = rest.split('?')[0].split('#')[0]
            name = urllib.parse.unquote(rest.split('#')[-1]) if '#' in rest else 'trojan'
            
            if ':' in server_port:
                server, port = server_port.rsplit(':', 1)
                port = re.sub(r'[^\d]', '', port)
            else:
                server, port = server_port, '443'
            
            return {
                'type': 'trojan',
                'tag': name,
                'server': server,
                'server_port': int(port) if port else 443,
                'password': urllib.parse.unquote(password)
            }
        except Exception as e:
            print(f"Trojan 解析失败: {e}")
            return None
    
    # Shadowsocks: ss://base64@server:port#name 或 ss://base64#name
    elif link.startswith('ss://'):
        try:
            match = link[5:]
            if '#' in match:
                main_part, name = match.rsplit('#', 1)
                name = urllib.parse.unquote(name)
            else:
                main_part, name = match, 'ss'
            
            if '@' in main_part:
                b64_part, server_part = main_part.split('@', 1)
                padding = 4 - len(b64_part) % 4
                if padding != 4:
                    b64_part += '=' * padding
                decoded = base64.b64decode(b64_part).decode('utf-8')
                method, password = decoded.split(':', 1) if ':' in decoded else (decoded, '')
                server, port = server_part.rsplit(':', 1) if ':' in server_part else (server_part, '443')
            else:
                padding = 4 - len(main_part) % 4
                if padding != 4:
                    main_part += '=' * padding
                decoded = base64.b64decode(main_part).decode('utf-8')
                method_pass, server_port = decoded.rsplit('@', 1)
                method, password = method_pass.split(':', 1) if ':' in method_pass else (method_pass, '')
                server, port = server_port.rsplit(':', 1) if ':' in server_port else (server_port, '443')
            
            port = re.sub(r'[^\d]', '', port)
            
            return {
                'type': 'shadowsocks',
                'tag': name,
                'server': server,
                'server_port': int(port) if port else 443,
                'method': method,
                'password': password
            }
        except Exception as e:
            print(f"Shadowsocks 解析失败: {e}")
            return None
    
    # SOCKS: socks://[user:pass@]server:port#name
    elif link.startswith('socks://') or link.startswith('socks5://'):
        try:
            idx = 8 if link.startswith('socks://') else 9
            match = link[idx:]
            if '#' in match:
                main_part, name = match.rsplit('#', 1)
                name = urllib.parse.unquote(name)
            else:
                main_part, name = match, 'socks'
            
            username = password = ''
            if '@' in main_part:
                auth, server_part = main_part.rsplit('@', 1)
                if ':' in auth:
                    username, password = auth.split(':', 1)
                else:
                    username = auth
            else:
                server_part = main_part
            
            server, port = server_part.rsplit(':', 1) if ':' in server_part else (server_part, '1080')
            port = re.sub(r'[^\d]', '', port)
            
            return {
                'type': 'socks',
                'tag': name,
                'server': server,
                'server_port': int(port) if port else 1080,
                'username': username,
                'password': password
            }
        except Exception as e:
            print(f"SOCKS 解析失败: {e}")
            return None
    
    # Hysteria2: hy2://auth@server:port?params#name
    elif link.startswith('hy2://') or link.startswith('hysteria2://'):
        try:
            idx = 6 if link.startswith('hy2://') else 12
            match = link[idx:]
            
            if '@' not in match:
                return None
            
            auth, rest = match.split('@', 1)
            
            # 提取 server:port
            server_port = rest.split('?')[0].split('#')[0]
            
            # 提取名称
            name = 'hy2'
            if '#' in rest:
                name = urllib.parse.unquote(rest.split('#')[-1])
            
            # 解析 server 和 port
            if ':' in server_port:
                server, port = server_port.rsplit(':', 1)
                port = re.sub(r'[^\d]', '', port)
            else:
                server, port = server_port, '443'
            
            return {
                'type': 'hysteria2',
                'tag': name,
                'server': server,
                'server_port': int(port) if port else 443,
                'password': urllib.parse.unquote(auth)
            }
        except Exception as e:
            print(f"Hysteria2 解析失败: {e}")
            return None
    
    # TUIC: tuic://uuid:password@server:port?params#name
    elif link.startswith('tuic://'):
        try:
            match = link[7:]
            
            if '@' not in match:
                return None
            
            uuid_pass, rest = match.split('@', 1)
            uuid, password = uuid_pass.split(':', 1) if ':' in uuid_pass else (uuid_pass, '')
            
            server_port = rest.split('?')[0].split('#')[0]
            name = urllib.parse.unquote(rest.split('#')[-1]) if '#' in rest else 'tuic'
            
            if ':' in server_port:
                server, port = server_port.rsplit(':', 1)
                port = re.sub(r'[^\d]', '', port)
            else:
                server, port = server_port, '443'
            
            return {
                'type': 'tuic',
                'tag': name,
                'server': server,
                'server_port': int(port) if port else 443,
                'uuid': uuid,
                'password': urllib.parse.unquote(password)
            }
        except Exception as e:
            print(f"TUIC 解析失败: {e}")
            return None
    
    return None

@app.route('/api/outbounds/parse', methods=['POST'])
@login_required
def api_parse_outbounds():
    """解析代理链接"""
    data = request.get_json()
    links_text = data.get('links', '')
    
    results = []
    for line in links_text.split('\n'):
        line = line.strip()
        if line:
            parsed = parse_proxy_link(line)
            if parsed:
                results.append(parsed)
    
    return jsonify({'success': True, 'data': results})

@app.route('/api/outbounds/batch', methods=['POST'])
@login_required
def api_batch_add_outbounds():
    """批量添加出站"""
    data = request.get_json()
    outbounds_to_add = data.get('outbounds', [])
    
    config = load_config()
    singbox_config = load_singbox_config()
    
    count = 0
    existing_tags = {o.get('tag') for o in config.get('outbounds', [])}
    
    for outbound in outbounds_to_add:
        tag = outbound.get('tag')
        # 确保 tag 唯一
        original_tag = tag
        suffix = 1
        while tag in existing_tags:
            tag = f'{original_tag}-{suffix}'
            suffix += 1
        
        outbound['tag'] = tag
        outbound['created_at'] = datetime.now().isoformat()
        
        # Panel 配置
        config.setdefault('outbounds', []).append(outbound)
        
        # Sing-box 配置
        singbox_outbound = build_singbox_outbound(outbound)
        if singbox_outbound:
            singbox_config.setdefault('outbounds', []).append(singbox_outbound)
            existing_tags.add(tag)
            count += 1
    
    save_config(config)
    save_singbox_config(singbox_config)
    
    return jsonify({'success': True, 'count': count})

def build_singbox_outbound(data):
    """构建 sing-box 出站配置"""
    outbound_type = data.get('type')
    tag = data.get('tag')
    server = data.get('server')
    port = data.get('server_port')
    
    if not all([outbound_type, tag, server, port]):
        return None
    
    singbox_outbound = {
        'type': outbound_type,
        'tag': tag,
        'server': server,
        'server_port': port
    }
    
    if outbound_type == 'vless':
        singbox_outbound['uuid'] = data.get('uuid', '')
        singbox_outbound['tls'] = {'enabled': True}
    
    elif outbound_type == 'vmess':
        singbox_outbound['uuid'] = data.get('uuid', '')
        singbox_outbound['alter_id'] = data.get('alter_id', 0)
        singbox_outbound['security'] = 'auto'
    
    elif outbound_type == 'trojan':
        singbox_outbound['password'] = data.get('password', '')
        singbox_outbound['tls'] = {'enabled': True}
    
    elif outbound_type == 'shadowsocks':
        singbox_outbound['method'] = data.get('method', 'aes-256-gcm')
        singbox_outbound['password'] = data.get('password', '')
    
    elif outbound_type == 'socks':
        if data.get('username'):
            singbox_outbound['username'] = data.get('username')
        if data.get('password'):
            singbox_outbound['password'] = data.get('password')
    
    elif outbound_type == 'hysteria2':
        singbox_outbound['password'] = data.get('password', '')
        singbox_outbound['tls'] = {'enabled': True, 'insecure': True}
    
    elif outbound_type == 'tuic':
        singbox_outbound['uuid'] = data.get('uuid', '')
        singbox_outbound['password'] = data.get('password', '')
        singbox_outbound['congestion_control'] = 'bbr'
        singbox_outbound['tls'] = {'enabled': True, 'insecure': True}
    
    return singbox_outbound

@app.route('/api/outbounds', methods=['POST'])
@login_required
def api_add_outbound():
    data = request.get_json()
    
    tag = data.get('tag')
    server = data.get('server')
    port = int(data.get('server_port', 443))
    outbound_type = data.get('type', 'socks')
    
    if not tag or not server:
        return jsonify({'success': False, 'error': '标签和服务器地址必填'})
    
    config = load_config()
    singbox_config = load_singbox_config()
    
    # 检查标签
    for outbound in config.get('outbounds', []):
        if outbound.get('tag') == tag:
            return jsonify({'success': False, 'error': f'标签 {tag} 已存在'})
    
    panel_outbound = {
        'type': outbound_type,
        'tag': tag,
        'server': server,
        'server_port': port,
        'created_at': datetime.now().isoformat()
    }
    
    # 根据类型添加字段
    for key in ['uuid', 'password', 'username', 'method', 'alter_id']:
        if data.get(key):
            panel_outbound[key] = data.get(key)
    
    singbox_outbound = build_singbox_outbound(panel_outbound)
    
    config.setdefault('outbounds', []).append(panel_outbound)
    singbox_config.setdefault('outbounds', []).append(singbox_outbound)
    
    save_config(config)
    save_singbox_config(singbox_config)
    
    return jsonify({'success': True, 'data': panel_outbound})

@app.route('/api/outbounds/<tag>', methods=['DELETE'])
@login_required
def api_delete_outbound(tag):
    config = load_config()
    singbox_config = load_singbox_config()
    
    config['outbounds'] = [o for o in config.get('outbounds', []) if o.get('tag') != tag]
    singbox_config['outbounds'] = [o for o in singbox_config.get('outbounds', []) if o.get('tag') != tag]
    
    save_config(config)
    save_singbox_config(singbox_config)
    
    return jsonify({'success': True})

@app.route('/api/outbounds/<tag>', methods=['PUT'])
@login_required
def api_edit_outbound(tag):
    """编辑出站配置"""
    data = request.get_json()
    config = load_config()
    singbox_config = load_singbox_config()
    
    # 查找出站
    outbound_idx = None
    for i, outbound in enumerate(config.get('outbounds', [])):
        if outbound.get('tag') == tag:
            outbound_idx = i
            break
    
    if outbound_idx is None:
        return jsonify({'success': False, 'error': f'出站 {tag} 不存在'})
    
    # 更新支持的字段
    updateable_fields = ['server', 'server_port', 'uuid', 'password', 'username', 'method', 'sni', 'remark']
    for field in updateable_fields:
        if field in data:
            config['outbounds'][outbound_idx][field] = data[field]
    
    # 同步更新 singbox 配置
    for i, outbound in enumerate(singbox_config.get('outbounds', [])):
        if outbound.get('tag') == tag:
            if 'server' in data:
                singbox_config['outbounds'][i]['server'] = data['server']
            if 'server_port' in data:
                singbox_config['outbounds'][i]['server_port'] = int(data['server_port'])
            if 'uuid' in data:
                singbox_config['outbounds'][i]['uuid'] = data['uuid']
            if 'password' in data:
                singbox_config['outbounds'][i]['password'] = data['password']
            break
    
    save_config(config)
    save_singbox_config(singbox_config)
    
    return jsonify({'success': True, 'data': config['outbounds'][outbound_idx]})

# --- 中转规则 API ---
@app.route('/api/routes')
@login_required
def api_routes():
    config = load_config()
    return jsonify({'success': True, 'data': config.get('routes', [])})

@app.route('/api/routes', methods=['POST'])
@login_required
def api_add_route():
    data = request.get_json()
    
    route_type = data.get('type', 'one-to-one')
    inbound = data.get('inbound')
    outbound = data.get('outbound')
    outbounds = data.get('outbounds', [])
    
    if not inbound:
        return jsonify({'success': False, 'error': '请选择入站'})
    
    config = load_config()
    singbox_config = load_singbox_config()
    
    name = data.get('name') or f'{inbound}-to-{outbound or "multi"}'
    
    route = {
        'name': name,
        'type': route_type,
        'inbound': inbound,
        'created_at': datetime.now().isoformat()
    }
    
    singbox_rule = {
        'inbound': [inbound]
    }
    
    if route_type == 'one-to-one':
        if not outbound:
            return jsonify({'success': False, 'error': '请选择出站'})
        route['outbound'] = outbound
        singbox_rule['outbound'] = outbound
    else:
        if len(outbounds) < 2:
            return jsonify({'success': False, 'error': '至少选择2个出站'})
        route['outbounds'] = outbounds
        
        # 创建负载均衡出站组
        lb_outbound = {
            'type': 'urltest',
            'tag': name,
            'outbounds': outbounds,
            'url': 'https://www.gstatic.com/generate_204',
            'interval': '3m'
        }
        singbox_config.setdefault('outbounds', []).append(lb_outbound)
        singbox_rule['outbound'] = name
    
    config.setdefault('routes', []).append(route)
    singbox_config.setdefault('route', {}).setdefault('rules', []).append(singbox_rule)
    
    save_config(config)
    save_singbox_config(singbox_config)
    restart_service()
    
    return jsonify({'success': True, 'data': route})

@app.route('/api/routes/<name>', methods=['DELETE'])
@login_required
def api_delete_route(name):
    config = load_config()
    singbox_config = load_singbox_config()
    
    config['routes'] = [r for r in config.get('routes', []) if r.get('name') != name]
    
    # 删除对应的 sing-box 规则和出站组
    singbox_config['outbounds'] = [o for o in singbox_config.get('outbounds', []) if o.get('tag') != name]
    
    # 重新生成路由规则
    new_rules = []
    for route in config.get('routes', []):
        rule = {'inbound': [route.get('inbound')]}
        if route.get('type') == 'one-to-one':
            rule['outbound'] = route.get('outbound')
        else:
            rule['outbound'] = route.get('name')
        new_rules.append(rule)
    
    singbox_config.setdefault('route', {})['rules'] = new_rules
    
    save_config(config)
    save_singbox_config(singbox_config)
    restart_service()
    
    return jsonify({'success': True})

# --- 密码修改 API ---
@app.route('/api/password', methods=['POST'])
@login_required
def api_change_password():
    data = request.get_json()
    new_password = data.get('password')
    
    if not new_password or len(new_password) < 6:
        return jsonify({'success': False, 'error': '密码至少6位'})
    
    config = load_config()
    config['panel']['admin_pass_hash'] = hash_password(new_password)
    config['panel']['admin_pass_plain'] = new_password
    save_config(config)
    
    return jsonify({'success': True})

# --- 配置管理 API ---
@app.route('/api/config')
@login_required
def api_get_config():
    config = load_config()
    panel = config.get('panel', {})
    return jsonify({
        'success': True,
        'data': {
            'web_port': panel.get('web_port', 8080),
            'server_ip': panel.get('server_ip', ''),
            'domain': panel.get('domain', '')
        }
    })

def apply_ssl_certificate(domain):
    """使用 acme.sh 申请 SSL 证书"""
    import shutil
    cert_dir = os.path.join(CONFIG_DIR, 'certs')
    os.makedirs(cert_dir, exist_ok=True)
    
    cert_path = os.path.join(cert_dir, f'{domain}.crt')
    key_path = os.path.join(cert_dir, f'{domain}.key')
    fullchain_path = os.path.join(cert_dir, f'{domain}.fullchain.crt')
    
    # gunicorn 使用的固定文件名
    panel_cert = os.path.join(cert_dir, 'panel.crt')
    panel_key = os.path.join(cert_dir, 'panel.key')
    
    # 检查 acme.sh 是否安装
    acme_path = os.path.expanduser('~/.acme.sh/acme.sh')
    if not os.path.exists(acme_path):
        # 尝试其他常见路径
        alt_paths = ['/root/.acme.sh/acme.sh', '/usr/local/bin/acme.sh']
        for p in alt_paths:
            if os.path.exists(p):
                acme_path = p
                break
        else:
            return False, 'acme.sh 未安装，请先运行: curl https://get.acme.sh | sh'
    
    def copy_certs_to_panel():
        """将域名证书复制到 panel.crt/panel.key 供 gunicorn 使用"""
        try:
            # 优先使用 fullchain 证书
            src_cert = fullchain_path if os.path.exists(fullchain_path) else cert_path
            if os.path.exists(src_cert) and os.path.exists(key_path):
                shutil.copy2(src_cert, panel_cert)
                shutil.copy2(key_path, panel_key)
                os.chmod(panel_key, 0o600)
                return True
        except Exception as e:
            print(f"复制证书失败: {e}")
        return False
    
    try:
        # 使用 standalone 模式申请证书 (需要 80 端口)
        result = subprocess.run([
            acme_path, '--issue', '-d', domain,
            '--standalone', '--force',
            '--cert-file', cert_path,
            '--key-file', key_path,
            '--fullchain-file', fullchain_path
        ], capture_output=True, text=True, timeout=120)
        
        if result.returncode == 0 or os.path.exists(cert_path):
            os.chmod(key_path, 0o600)
            # 复制证书到 panel.crt/panel.key
            if copy_certs_to_panel():
                return True, '证书申请成功并已应用'
            return True, '证书申请成功，但复制到面板证书失败'
        else:
            # 尝试使用 webroot 模式
            webroot = '/var/www/html'
            if os.path.exists(webroot):
                result = subprocess.run([
                    acme_path, '--issue', '-d', domain,
                    '-w', webroot, '--force',
                    '--cert-file', cert_path,
                    '--key-file', key_path,
                    '--fullchain-file', fullchain_path
                ], capture_output=True, text=True, timeout=120)
                
                if result.returncode == 0 or os.path.exists(cert_path):
                    os.chmod(key_path, 0o600)
                    # 复制证书到 panel.crt/panel.key
                    if copy_certs_to_panel():
                        return True, '证书申请成功并已应用'
                    return True, '证书申请成功，但复制到面板证书失败'
            
            error_msg = result.stderr or result.stdout or '证书申请失败'
            return False, f'证书申请失败: {error_msg[:200]}'
    except subprocess.TimeoutExpired:
        return False, '证书申请超时，请检查域名解析是否正确'
    except Exception as e:
        return False, f'证书申请出错: {str(e)}'

@app.route('/api/config', methods=['POST'])
@login_required
def api_update_config():
    data = request.get_json()
    config = load_config()
    
    old_port = config['panel'].get('web_port', 8080)
    old_domain = config['panel'].get('domain', '')
    port_changed = False
    domain_changed = False
    new_port = old_port
    new_domain = old_domain
    
    if 'web_port' in data:
        new_port = int(data['web_port'])
        if new_port != old_port:
            config['panel']['web_port'] = new_port
            port_changed = True
    
    if 'domain' in data:
        new_domain = data['domain'].strip()
        if new_domain != old_domain:
            config['panel']['domain'] = new_domain
            domain_changed = True
    
    save_config(config)
    
    messages = []
    cert_success = False
    
    # 如果端口改变，需要更新 systemd 服务文件并延迟重启服务
    if port_changed:
        try:
            # 读取并更新 systemd 服务文件
            service_path = '/etc/systemd/system/transit-panel-web.service'
            if os.path.exists(service_path):
                with open(service_path, 'r') as f:
                    content = f.read()
                
                # 替换端口
                import re
                content = re.sub(r'-b 0\.0\.0\.0:\d+', f'-b 0.0.0.0:{new_port}', content)
                
                with open(service_path, 'w') as f:
                    f.write(content)
                
                # 重新加载 systemd 配置
                subprocess.run(['systemctl', 'daemon-reload'], check=True)
                
                # 使用后台线程延迟重启服务，避免响应丢失
                import threading
                def delayed_restart():
                    import time
                    time.sleep(2)  # 等待2秒确保响应已发送
                    try:
                        subprocess.run(['systemctl', 'restart', 'transit-panel-web'], check=True)
                    except Exception as e:
                        print(f"服务重启失败: {e}")
                
                restart_thread = threading.Thread(target=delayed_restart, daemon=True)
                restart_thread.start()
                
                messages.append(f'端口已更新为 {new_port}，服务将在2秒后重启，请使用新端口 https://您的IP:{new_port} 访问')
            else:
                messages.append(f'端口配置已保存为 {new_port}，服务文件不存在，请手动重启服务')
        except Exception as e:
            messages.append(f'端口配置已保存，但服务重启失败: {str(e)}')
    
    # 如果域名改变，自动申请 SSL 证书
    if domain_changed and new_domain:
        success, cert_msg = apply_ssl_certificate(new_domain)
        cert_success = success
        if success:
            # 保存证书路径到配置 (使用固定的 panel.crt/panel.key)
            config['panel']['ssl_cert'] = os.path.join(CONFIG_DIR, 'certs', 'panel.crt')
            config['panel']['ssl_key'] = os.path.join(CONFIG_DIR, 'certs', 'panel.key')
            save_config(config)
            messages.append(f'域名 {new_domain} 的 SSL 证书: {cert_msg}')
            
            # 延迟重启服务以应用新证书
            import threading
            def delayed_restart_for_cert():
                import time
                time.sleep(2)
                try:
                    subprocess.run(['systemctl', 'restart', 'transit-panel-web'], check=True)
                except Exception as e:
                    print(f"证书应用后服务重启失败: {e}")
            
            restart_thread = threading.Thread(target=delayed_restart_for_cert, daemon=True)
            restart_thread.start()
            messages.append('服务将在2秒后重启以应用新证书')
        else:
            messages.append(f'域名已保存，但证书申请失败: {cert_msg}')
    elif domain_changed and not new_domain:
        # 域名被清空
        config['panel'].pop('ssl_cert', None)
        config['panel'].pop('ssl_key', None)
        save_config(config)
        messages.append('域名已清空')
    
    final_message = '；'.join(messages) if messages else '配置已保存'
    
    return jsonify({
        'success': True, 
        'message': final_message,
        'port_changed': port_changed,
        'new_port': new_port if port_changed else None,
        'cert_applied': cert_success
    })

# --- Clash 订阅链接 API ---
@app.route('/api/subscribe/clash')
def api_clash_subscription():
    """生成 Clash 订阅配置"""
    config = load_config()
    inbounds = config.get('inbounds', [])
    server_ip = config.get('panel', {}).get('server_ip', get_public_ip())
    
    proxies = []
    for inbound in inbounds:
        proxy = None
        
        if inbound.get('type') == 'hysteria2':
            proxy = {
                'name': inbound.get('tag'),
                'type': 'hysteria2',
                'server': server_ip,
                'port': inbound.get('port'),
                'password': inbound.get('password', ''),
                'skip-cert-verify': True
            }
        
        elif inbound.get('type') == 'tuic':
            proxy = {
                'name': inbound.get('tag'),
                'type': 'tuic',
                'server': server_ip,
                'port': inbound.get('port'),
                'uuid': inbound.get('uuid', ''),
                'password': inbound.get('password', ''),
                'congestion-controller': 'bbr',
                'udp-relay-mode': 'native',
                'alpn': ['h3'],
                'sni': 'www.bing.com',
                'skip-cert-verify': True
            }
        
        elif inbound.get('type') == 'vless-reality':
            proxy = {
                'name': inbound.get('tag'),
                'type': 'vless',
                'server': server_ip,
                'port': inbound.get('port'),
                'uuid': inbound.get('uuid', ''),
                'network': 'tcp',
                'tls': True,
                'servername': inbound.get('server_name', 'icloud.com'),
                'reality-opts': {
                    'public-key': inbound.get('public_key', ''),
                    'short-id': inbound.get('short_id', '')
                },
                'client-fingerprint': 'firefox'
            }
        
        if proxy:
            proxies.append(proxy)
    
    # 构建 Clash 配置
    import yaml
    
    clash_config = {
        'port': 7890,
        'socks-port': 7891,
        'allow-lan': False,
        'mode': 'rule',
        'log-level': 'info',
        'proxies': proxies,
        'proxy-groups': [
            {
                'name': '节点选择',
                'type': 'select',
                'proxies': [p['name'] for p in proxies] + ['DIRECT']
            },
            {
                'name': '自动选择',
                'type': 'url-test',
                'proxies': [p['name'] for p in proxies],
                'url': 'http://www.gstatic.com/generate_204',
                'interval': 300
            }
        ] if proxies else [],
        'rules': [
            'GEOIP,CN,DIRECT',
            'MATCH,节点选择'
        ]
    }
    
    from flask import Response
    yaml_content = yaml.dump(clash_config, allow_unicode=True, default_flow_style=False)
    return Response(yaml_content, mimetype='text/yaml', headers={'Content-Disposition': 'attachment; filename=clash_config.yaml'})

# --- 二维码生成 API ---
@app.route('/api/qrcode/<tag>')
@login_required
def api_qrcode(tag):
    """生成节点二维码"""
    config = load_config()
    
    # 查找入站
    inbound = None
    for i in config.get('inbounds', []):
        if i.get('tag') == tag:
            inbound = i
            break
    
    if not inbound or not inbound.get('share_link'):
        return jsonify({'success': False, 'error': '节点不存在或无分享链接'})
    
    try:
        import qrcode
        import io
        import base64
        
        qr = qrcode.QRCode(version=1, box_size=10, border=2)
        qr.add_data(inbound.get('share_link'))
        qr.make(fit=True)
        
        img = qr.make_image(fill_color='black', back_color='white')
        buffer = io.BytesIO()
        img.save(buffer, format='PNG')
        buffer.seek(0)
        
        # 返回 base64 编码的图片
        img_base64 = base64.b64encode(buffer.getvalue()).decode('utf-8')
        return jsonify({
            'success': True,
            'data': {
                'qrcode': f'data:image/png;base64,{img_base64}',
                'share_link': inbound.get('share_link')
            }
        })
    except ImportError:
        # 如果没有安装 qrcode 模块，返回使用第三方 API 生成的链接
        import urllib.parse
        share_link = inbound.get('share_link', '')
        api_url = f'https://api.qrserver.com/v1/create-qr-code/?size=300x300&data={urllib.parse.quote(share_link)}'
        return jsonify({
            'success': True,
            'data': {
                'qrcode': api_url,
                'share_link': share_link
            }
        })
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

# ==================== 启动 ====================
if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=False)

