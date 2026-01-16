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
app.secret_key = secrets.token_hex(32)
app.permanent_session_lifetime = timedelta(hours=24)

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
    
    tag = data.get('tag', f'{protocol}-in')
    port = int(data.get('port', 443))
    
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
            'tls': {
                'enabled': True,
                'certificate_path': cert_path,
                'key_path': key_path
            }
        })
        
        share_link = f'tuic://{uuid}:{password}@{server_ip}:{port}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#{tag}'
        
    elif protocol == 'vless-reality':
        uuid = data.get('uuid') or generate_uuid()
        server_name = data.get('server_name', 'www.microsoft.com')
        private_key, public_key = generate_reality_keypair()
        short_id = secrets.token_hex(8)
        
        panel_inbound.update({
            'uuid': uuid,
            'server_name': server_name,
            'public_key': public_key,
            'short_id': short_id
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
        
        share_link = f'vless://{uuid}@{server_ip}:{port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni={server_name}&fp=chrome&pbk={public_key}&sid={short_id}&type=tcp&headerType=none#{tag}'
    
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

# --- 出站 API ---
@app.route('/api/outbounds')
@login_required
def api_outbounds():
    config = load_config()
    return jsonify({'success': True, 'data': config.get('outbounds', [])})

@app.route('/api/outbounds', methods=['POST'])
@login_required
def api_add_outbound():
    data = request.get_json()
    
    tag = data.get('tag')
    server = data.get('server')
    port = int(data.get('port', 1080))
    username = data.get('username', '')
    password = data.get('password', '')
    
    if not tag or not server:
        return jsonify({'success': False, 'error': '标签和服务器地址必填'})
    
    config = load_config()
    singbox_config = load_singbox_config()
    
    # 检查标签
    for outbound in config.get('outbounds', []):
        if outbound.get('tag') == tag:
            return jsonify({'success': False, 'error': f'标签 {tag} 已存在'})
    
    panel_outbound = {
        'type': 'socks',
        'tag': tag,
        'server': server,
        'server_port': port,
        'username': username,
        'password': password,
        'created_at': datetime.now().isoformat()
    }
    
    singbox_outbound = {
        'type': 'socks',
        'tag': tag,
        'server': server,
        'server_port': port
    }
    
    if username and password:
        singbox_outbound['username'] = username
        singbox_outbound['password'] = password
    
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
    save_config(config)
    
    return jsonify({'success': True})

# ==================== 启动 ====================
if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=False)
