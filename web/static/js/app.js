/**
 * Transit Panel - Frontend JavaScript
 */

// Toast 通知
function showToast(message, type = 'info') {
    const container = document.getElementById('toast-container');
    if (!container) return;

    const toast = document.createElement('div');
    toast.className = `toast ${type}`;
    toast.innerHTML = `
        <span>${type === 'success' ? '✓' : type === 'error' ? '✗' : 'ℹ'}</span>
        <span>${message}</span>
    `;

    container.appendChild(toast);

    setTimeout(() => {
        toast.style.animation = 'slideIn 0.3s ease reverse';
        setTimeout(() => toast.remove(), 300);
    }, 3000);
}

// 复制到剪贴板
async function copyToClipboard(text) {
    try {
        await navigator.clipboard.writeText(text);
        showToast('已复制到剪贴板', 'success');
    } catch (err) {
        // Fallback
        const textarea = document.createElement('textarea');
        textarea.value = text;
        textarea.style.position = 'fixed';
        textarea.style.opacity = '0';
        document.body.appendChild(textarea);
        textarea.select();
        document.execCommand('copy');
        document.body.removeChild(textarea);
        showToast('已复制到剪贴板', 'success');
    }
}

// API 请求封装
async function apiRequest(url, options = {}) {
    try {
        const response = await fetch(url, {
            headers: {
                'Content-Type': 'application/json',
                ...options.headers
            },
            ...options
        });

        const data = await response.json();

        if (response.status === 401) {
            window.location.href = '/login';
            return null;
        }

        return data;
    } catch (error) {
        console.error('API Error:', error);
        showToast('请求失败，请检查网络', 'error');
        return null;
    }
}

// 格式化日期
function formatDate(dateString) {
    if (!dateString) return '-';
    const date = new Date(dateString);
    return date.toLocaleDateString('zh-CN', {
        year: 'numeric',
        month: '2-digit',
        day: '2-digit',
        hour: '2-digit',
        minute: '2-digit'
    });
}

// 刷新状态
async function refreshStatus() {
    const data = await apiRequest('/api/status');
    if (data && data.success) {
        // 更新页面上的统计数据
        const stats = data.data;

        const serviceStatus = document.querySelector('.stat-icon.service');
        if (serviceStatus) {
            serviceStatus.className = `stat-icon service ${stats.service_running ? 'online' : 'offline'}`;
            serviceStatus.textContent = stats.service_running ? '✓' : '✗';
        }
    }
}

// 移动端菜单切换
function toggleSidebar() {
    const sidebar = document.querySelector('.sidebar');
    if (sidebar) {
        sidebar.classList.toggle('open');
    }
}

// 初始化
document.addEventListener('DOMContentLoaded', function () {
    // 定期刷新状态 (每30秒)
    if (document.querySelector('.dashboard')) {
        setInterval(refreshStatus, 30000);
    }
});

// 确认对话框
function confirmAction(message) {
    return confirm(message);
}

// 生成随机字符串
function generateRandomString(length = 16) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    let result = '';
    for (let i = 0; i < length; i++) {
        result += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return result;
}

// 生成 UUID
function generateUUID() {
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) {
        const r = Math.random() * 16 | 0;
        const v = c === 'x' ? r : (r & 0x3 | 0x8);
        return v.toString(16);
    });
}
