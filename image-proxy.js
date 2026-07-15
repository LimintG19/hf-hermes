/**
 * Media Proxy + BFF Reverse Proxy
 *
 * 在 BFF (hermes-web-ui) 前端增加一层轻量代理:
 *   - /files/           → 列出所有媒体文件 (HTML 页面，支持分类/排序/分页)
 *   - /files/<file>     → 直接下载/预览媒体文件
 *   - 其他所有请求       → 透传给 BFF (含 WebSocket)
 *
 * 支持格式:
 *   - 图片: png, jpg, jpeg, gif, webp, svg, bmp
 *   - 视频: mp4, avi, mov, mkv, webm, m4v, 3gp
 *   - 音频: mp3, wav, aac, ogg, flac, m4a, wma
 *   - 文档: md, pdf, txt, json
 *
 * 端口: 7860 (HF Spaces 对外端口)
 * BFF:  7861 (内部端口, 仅本代理访问)
 * 媒体目录: /data/.hermes/image_cache (主目录)
 *           /data/cover-image (baoyu-cover-image 输出目录)
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const net = require('net');

const BFF_HOST = '127.0.0.1';
const BFF_PORT = parseInt(process.env.BFF_PORT || '7861', 10);
const LISTEN_PORT = parseInt(process.env.LISTEN_PORT || '7860', 10);
const IMAGE_DIR = process.env.IMAGE_DIR || '/data/.hermes/image_cache';
const PAGE_SIZE = 20; // 每页默认显示文件数
const SESSIONS_DIR = '/data/.hermes/sessions';
// 额外的媒体搜索路径
const EXTRA_MEDIA_DIRS = [
  '/data/cover-image',
  '/data/.hermes/image_cache',
];

// MIME 类型映射
const MIME_TYPES = {
  // 图片
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
  '.bmp': 'image/bmp',
  // 视频
  '.mp4': 'video/mp4',
  '.avi': 'video/avi',
  '.mov': 'video/quicktime',
  '.mkv': 'video/x-matroska',
  '.webm': 'video/webm',
  '.m4v': 'video/x-m4v',
  '.3gp': 'video/3gpp',
  // 音频
  '.mp3': 'audio/mpeg',
  '.wav': 'audio/wav',
  '.aac': 'audio/aac',
  '.ogg': 'audio/ogg',
  '.flac': 'audio/flac',
  '.m4a': 'audio/mp4',
  '.wma': 'audio/x-ms-wma',
  // 文档
  '.pdf': 'application/pdf',
  '.md': 'text/markdown',
  '.txt': 'text/plain',
  '.json': 'application/json',
};

// 文件分类配置
const FILE_TYPES = {
  image: {
    exts: ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg', '.bmp'],
    label: '图片',
    icon: '🖼️',
    badgeColor: '#4CAF50'
  },
  video: {
    exts: ['.mp4', '.avi', '.mov', '.mkv', '.webm', '.m4v', '.3gp'],
    label: '视频',
    icon: '🎬',
    badgeColor: '#FF5722'
  },
  audio: {
    exts: ['.mp3', '.wav', '.aac', '.ogg', '.flac', '.m4a', '.wma'],
    label: '音频',
    icon: '🎵',
    badgeColor: '#9C27B0'
  },
  document: {
    exts: ['.pdf', '.md', '.txt', '.json'],
    label: '文档',
    icon: '📄',
    badgeColor: '#2196F3'
  }
};

// ==================== 辅助函数 ====================

function getFileCategory(filename) {
  const ext = path.extname(filename).toLowerCase();
  for (const [cat, info] of Object.entries(FILE_TYPES)) {
    if (info.exts.includes(ext)) return cat;
  }
  return 'other';
}

function getFileIcon(filename) {
  const cat = getFileCategory(filename);
  return FILE_TYPES[cat]?.icon || '📎';
}

function getMimeType(filename) {
  const ext = path.extname(filename).toLowerCase();
  return MIME_TYPES[ext] || 'application/octet-stream';
}

function formatFileSize(bytes) {
  if (bytes < 1024) return bytes + ' B';
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
  if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(2) + ' MB';
  return (bytes / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
}

function renderMedia(file) {
  const url = `/files/${encodeURIComponent(file.relPath)}`;
  const mimeType = getMimeType(file.name);
  
  switch (file.category) {
    case 'image':
      return `<img src="${url}" alt="${file.name}" loading="lazy" onclick="window.open('${url}', '_blank')" />`;
    
    case 'video':
      return `<video controls width="100%" preload="metadata">
        <source src="${url}" type="${mimeType}">
        您的浏览器不支持视频播放
      </video>`;
    
    case 'audio':
      return `<div class="audio-player">
        <div class="audio-icon">🎵</div>
        <audio controls style="width:100%">
          <source src="${url}" type="${mimeType}">
          您的浏览器不支持音频播放
        </audio>
      </div>`;
    
    case 'document':
      const ext = path.extname(file.name).toLowerCase();
      if (ext === '.pdf') {
        return `<embed src="${url}" type="application/pdf" width="100%" height="400px" />
          <div class="doc-fallback">
            <a href="${url}" target="_blank">📖 在新窗口打开 PDF</a>
          </div>`;
      } else if (ext === '.md') {
        return `<div class="doc-preview-box">
          <div class="doc-icon-large">📝 Markdown</div>
          <a href="${url}?preview=1" class="preview-btn" target="_blank">📖 预览文档</a>
        </div>`;
      } else {
        return `<div class="doc-preview-box">
          <div class="doc-icon-large">📄 ${ext.toUpperCase()}</div>
          <a href="${url}" download class="preview-btn">⬇️ 下载文件</a>
        </div>`;
      }
    
    default:
      return `<div class="file-preview-box">
        <div class="file-icon-large">📎 ${path.extname(file.name) || '文件'}</div>
        <a href="${url}" download class="preview-btn">⬇️ 下载</a>
      </div>`;
  }
}

// ==================== 媒体文件列表服务 ====================

function serveImageList(req, res, query) {
  const allFiles = [];
  let dirsScanned = 0;
  const totalDirs = EXTRA_MEDIA_DIRS.length;

  function checkComplete() {
    dirsScanned++;
    if (dirsScanned < totalDirs) return;

    // 去重
    const uniqueFiles = Array.from(new Map(allFiles.map(f => [f.path, f])).values());
    
    // 排序（默认时间倒序）
    const sortBy = query.sort || 'time';
    if (sortBy === 'time') {
      uniqueFiles.sort((a, b) => b.mtime - a.mtime);
    } else if (sortBy === 'name') {
      uniqueFiles.sort((a, b) => a.name.localeCompare(b.name));
    } else if (sortBy === 'size') {
      uniqueFiles.sort((a, b) => b.size - a.size);
    }

    // 过滤
    const category = query.category || 'all';
    let filteredFiles = uniqueFiles;
    if (category !== 'all' && FILE_TYPES[category]) {
      filteredFiles = uniqueFiles.filter(f => f.category === category);
    }

    // 分页
    const totalFiles = filteredFiles.length;
    const totalPages = Math.ceil(totalFiles / PAGE_SIZE) || 1;
    const currentPage = Math.min(Math.max(parseInt(query.page) || 1, 1), totalPages);
    const startIdx = (currentPage - 1) * PAGE_SIZE;
    const pageFiles = filteredFiles.slice(startIdx, startIdx + PAGE_SIZE);

    const html = buildMediaListHtml(pageFiles, {
      totalFiles,
      totalPages,
      currentPage,
      category,
      sortBy
    });
    
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(html);
  }

  EXTRA_MEDIA_DIRS.forEach(dir => {
    function scanDir(currentDir, relativePath, callback) {
      fs.readdir(currentDir, { withFileTypes: true }, (err, entries) => {
        if (err) {
          callback();
          return;
        }

        let pending = entries.length;
        if (pending === 0) {
          callback();
          return;
        }

        entries.forEach(entry => {
          const fullPath = path.join(currentDir, entry.name);
          const relPath = path.join(relativePath, entry.name);

          if (entry.isDirectory()) {
            scanDir(fullPath, relPath, () => {
              pending--;
              if (pending === 0) callback();
            });
          } else {
            const ext = path.extname(entry.name).toLowerCase();
            const isMedia = Object.values(FILE_TYPES).some(t => t.exts.includes(ext));
            
            if (isMedia) {
              try {
                const stat = fs.statSync(fullPath);
                allFiles.push({
                  name: entry.name,
                  path: fullPath,
                  relPath: relPath,
                  dir: dir,
                  size: stat.size,
                  mtime: stat.mtime,
                  category: getFileCategory(entry.name)
                });
              } catch (e) {}
            }
            
            pending--;
            if (pending === 0) callback();
          }
        });
      });
    }

    scanDir(dir, '', () => {
      checkComplete();
    });
  });
}

function buildMediaListHtml(files, pagination) {
  const { totalFiles, totalPages, currentPage, category, sortBy } = pagination;
  
  // 构建分类过滤按钮
  const filterButtons = [
    { key: 'all', label: '全部', icon: '📁' },
    { key: 'image', label: '图片', icon: '🖼️' },
    { key: 'video', label: '视频', icon: '🎬' },
    { key: 'audio', label: '音频', icon: '🎵' },
    { key: 'document', label: '文档', icon: '📄' },
  ].map(btn => {
    const active = category === btn.key ? 'active' : '';
    return `<a href="?category=${btn.key}&sort=${sortBy}" class="filter-btn ${active}">${btn.icon} ${btn.label}</a>`;
  }).join('');

  // 构建排序选项
  const sortOptions = [
    { key: 'time', label: '时间' },
    { key: 'name', label: '名称' },
    { key: 'size', label: '大小' },
  ].map(opt => {
    const active = sortBy === opt.key ? 'selected' : '';
    return `<option value="${opt.key}" ${active}>${opt.label}</option>`;
  }).join('');

  // 构建分页控件
  let paginationHtml = '';
  if (totalPages > 1) {
    const prevClass = currentPage <= 1 ? 'disabled' : '';
    const nextClass = currentPage >= totalPages ? 'disabled' : '';
    
    let pageButtons = '';
    const startPage = Math.max(1, currentPage - 2);
    const endPage = Math.min(totalPages, currentPage + 2);
    
    for (let i = startPage; i <= endPage; i++) {
      const active = i === currentPage ? 'active' : '';
      pageButtons += `<a href="?page=${i}&category=${category}&sort=${sortBy}" class="page-num ${active}">${i}</a>`;
    }
    
    paginationHtml = `
      <div class="pagination-bar">
        <a href="?page=1&category=${category}&sort=${sortBy}" class="page-btn ${prevClass}">⏮ 首页</a>
        <a href="?page=${currentPage - 1}&category=${category}&sort=${sortBy}" class="page-btn ${prevClass}">◀ 上一页</a>
        <div class="page-numbers">${pageButtons}</div>
        <span class="page-info">${currentPage} / ${totalPages} 页 (共 ${totalFiles} 个文件)</span>
        <a href="?page=${currentPage + 1}&category=${category}&sort=${sortBy}" class="page-btn ${nextClass}">下一页 ▶</a>
        <a href="?page=${totalPages}&category=${category}&sort=${sortBy}" class="page-btn ${nextClass}">末页 ⏭</a>
      </div>
    `;
  } else {
    paginationHtml = `<div class="pagination-bar"><span class="page-info">共 ${totalFiles} 个文件</span></div>`;
  }

  const html = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>📁 Media Cache - Hermes Agent</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
         background: #0f0f23; color: #e0e0e0; padding: 2em; min-height: 100vh; }
  h1 { color: #7eb8da; margin-bottom: 0.5em; font-size: 1.5em; }
  .subtitle { color: #888; font-size: 0.9em; margin-bottom: 1.5em; }
  
  /* 过滤器 */
  .filter-bar { display: flex; gap: 0.5em; margin-bottom: 1em; flex-wrap: wrap; align-items: center; }
  .filter-btn { 
    color: #b0b0d0; text-decoration: none; padding: 0.5em 1em;
    border: 1px solid #3a3a6e; border-radius: 8px; font-size: 0.9em;
    transition: all .2s; background: #1a1a3e; display: inline-flex; align-items: center; gap: 0.3em;
  }
  .filter-btn:hover { background: #2a2a5e; border-color: #7eb8da; }
  .filter-btn.active { background: #7eb8da; color: #0f0f23; border-color: #7eb8da; }
  
  .sort-select { 
    background: #1a1a3e; color: #b0b0d0; border: 1px solid #3a3a6e;
    padding: 0.5em 1em; border-radius: 8px; font-size: 0.9em; margin-left: auto;
  }
  .sort-select:focus { outline: none; border-color: #7eb8da; }
  
  /* 分页器 */
  .pagination-bar { 
    display: flex; gap: 0.5em; margin: 1.5em 0; align-items: center;
    justify-content: center; flex-wrap: wrap;
  }
  .page-btn { 
    color: #7eb8da; text-decoration: none; padding: 0.4em 0.8em;
    border: 1px solid #3a3a6e; border-radius: 6px; font-size: 0.85em;
    transition: all .2s;
  }
  .page-btn:hover:not(.disabled) { background: #7eb8da22; border-color: #7eb8da; }
  .page-btn.disabled { color: #555; border-color: #2a2a4e; pointer-events: none; }
  .page-num { 
    color: #b0b0d0; text-decoration: none; padding: 0.4em 0.8em;
    border: 1px solid #3a3a6e; border-radius: 6px; font-size: 0.85em; min-width: 2em; text-align: center;
  }
  .page-num.active { background: #7eb8da; color: #0f0f23; border-color: #7eb8da; }
  .page-num:hover:not(.active) { background: #2a2a5e; }
  .page-info { color: #888; font-size: 0.85em; margin: 0 1em; }
  
  /* 卡片 */
  .card { background: #1a1a3e; border-radius: 12px; padding: 1.5em;
          margin-bottom: 1.5em; box-shadow: 0 4px 12px rgba(0,0,0,.3); }
  .card h3 { color: #9dd6e8; margin-bottom: 0.8em; font-size: 1.1em; display: flex; align-items: center; gap: 0.5em; }
  .card img { max-width: 100%; border-radius: 8px; cursor: pointer;
              transition: transform .2s; display: block; }
  .card img:hover { transform: scale(1.01); }
  .card video { max-width: 100%; border-radius: 8px; display: block; }
  .card audio { width: 100%; margin: 0.5em 0; }
  
  .audio-player { display: flex; align-items: center; gap: 1em; padding: 1em; background: #0f0f23; border-radius: 8px; }
  .audio-icon { font-size: 2em; }
  
  .doc-preview-box, .file-preview-box { 
    background: #0f0f23; border-radius: 8px; padding: 2em; text-align: center;
    display: flex; flex-direction: column; align-items: center; gap: 1em;
  }
  .doc-icon-large { font-size: 3em; color: #7eb8da; }
  .file-icon-large { font-size: 3em; }
  .preview-btn { 
    color: #7eb8da; text-decoration: none; padding: 0.5em 1.5em;
    border: 1px solid #7eb8da; border-radius: 6px; transition: background .2s;
  }
  .preview-btn:hover { background: #7eb8da22; }
  .doc-fallback { margin-top: 0.5em; text-align: center; }
  
  embed { border-radius: 8px; }
  
  .actions { margin-top: 0.8em; display: flex; gap: 1em; flex-wrap: wrap; }
  .actions a { color: #7eb8da; text-decoration: none; padding: 0.4em 1em;
               border: 1px solid #7eb8da; border-radius: 6px; font-size: 0.9em;
               transition: background .2s; }
  .actions a:hover { background: #7eb8da22; }
  .meta { color: #888; font-size: 0.85em; margin-top: 0.5em; }
  .path { color: #666; font-size: 0.8em; margin-top: 0.3em; margin-bottom: 0.8em; }
  
  .badge { display: inline-block; padding: 0.2em 0.6em; border-radius: 4px; font-size: 0.75em; font-weight: bold; }
  .badge-image { background: #4CAF50; color: #fff; }
  .badge-video { background: #FF5722; color: #fff; }
  .badge-audio { background: #9C27B0; color: #fff; }
  .badge-document { background: #2196F3; color: #fff; }
  
  .empty { text-align: center; padding: 3em; color: #888; }
  .empty p { margin-top: 1em; font-size: 0.95em; }
  
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 1.5em; }
</style>
</head>
<body>
<h1>📁 Media Cache</h1>
<p class="subtitle">支持图片、视频、音频和文档预览</p>

<div class="filter-bar">
  ${filterButtons}
  <select class="sort-select" onchange="window.location.href='?category=${category}&sort='+this.value">
    <option value="">排序方式...</option>
    ${sortOptions}
  </select>
</div>

${paginationHtml}

${files.length === 0
? `<div class="empty"><p style="font-size:2em">📭</p><p>暂无媒体文件</p>
<p>提示: 上传文件到 /data/.hermes/image_cache/ 或 /data/cover-image/</p></div>`
  : `<div class="grid">${files.map(f => {
      const sizeStr = formatFileSize(f.size);
      const mtime = f.mtime.toISOString().replace('T', ' ').slice(0, 19);
      const badgeClass = `badge-${f.category}`;
      const badgeLabel = FILE_TYPES[f.category]?.label || '其他';
      const mediaTag = renderMedia(f);
      
      return `<div class="card">
  <h3>
    <span>${getFileIcon(f.name)}</span>
    ${f.name}
    <span class="badge ${badgeClass}">${badgeLabel}</span>
  </h3>
  <div class="path">${f.relPath}</div>
  ${mediaTag}
  <div class="meta">${sizeStr} · ${mtime}</div>
  <div class="actions">
    <a href="/files/${encodeURIComponent(f.relPath)}" download="${f.name}">⬇️ 下载</a>
    <a href="/files/${encodeURIComponent(f.relPath)}" target="_blank">🔍 查看</a>
  </div>
</div>`;
    }).join('\n')}</div>`
}

${paginationHtml}

<script>
  // 自动更新排序选择框的当前值
  document.querySelector('.sort-select').value = '${sortBy}';
</script>

</body></html>`;
  return html;
}

// ==================== 单个媒体文件服务 ====================

function serveImage(urlPath, query, res) {
  const relativePath = decodeURIComponent(urlPath.slice('/files/'.length));
  
  // 处理预览请求
  if (query.preview === '1') {
    return servePreview(relativePath, res);
  }

  // Try each media directory in order
  function tryDir(index) {
    if (index >= EXTRA_MEDIA_DIRS.length) {
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      res.end('Not found');
      return;
    }

    const dir = EXTRA_MEDIA_DIRS[index];
    const filePath = path.join(dir, relativePath);
    const resolved = path.resolve(filePath);

    // Security: prevent directory traversal
    const mediaRoot = path.resolve(dir);
    if (!resolved.startsWith(mediaRoot + path.sep) && resolved !== mediaRoot) {
      tryDir(index + 1);
      return;
    }

    fs.stat(resolved, (err, stat) => {
      if (err || !stat.isFile()) {
        tryDir(index + 1);
        return;
      }

      const ext = path.extname(resolved).toLowerCase();
      const contentType = MIME_TYPES[ext] || 'application/octet-stream';

      res.writeHead(200, {
        'Content-Type': contentType,
        'Content-Length': stat.size,
        'Cache-Control': 'public, max-age=3600',
        'Content-Disposition': `inline; filename="${path.basename(resolved)}"`,
      });
      fs.createReadStream(resolved).pipe(res);
    });
  }

  tryDir(0);
}

function servePreview(relativePath, res) {
  // 尝试找到文件
  function tryDir(index) {
    if (index >= EXTRA_MEDIA_DIRS.length) {
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      res.end('File not found');
      return;
    }

    const dir = EXTRA_MEDIA_DIRS[index];
    const filePath = path.join(dir, relativePath);
    const resolved = path.resolve(filePath);
    const mediaRoot = path.resolve(dir);
    
    if (!resolved.startsWith(mediaRoot + path.sep) && resolved !== mediaRoot) {
      tryDir(index + 1);
      return;
    }

    fs.readFile(resolved, 'utf-8', (err, data) => {
      if (err) {
        tryDir(index + 1);
        return;
      }

      const ext = path.extname(resolved).toLowerCase();
      
      if (ext === '.md') {
        // Markdown 预览
        const html = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>📖 ${path.basename(resolved)}</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
         max-width: 900px; margin: 2em auto; padding: 0 2em; line-height: 1.6; 
         background: #fafafa; color: #333; }
  h1, h2, h3 { color: #2c3e50; border-bottom: 2px solid #eee; padding-bottom: 0.3em; }
  code { background: #f0f0f0; padding: 0.2em 0.4em; border-radius: 3px; }
  pre { background: #f5f5f5; padding: 1em; border-radius: 8px; overflow-x: auto; }
  blockquote { border-left: 4px solid #ddd; margin-left: 0; padding-left: 1em; color: #666; }
  a { color: #3498db; }
  table { border-collapse: collapse; width: 100%; margin: 1em 0; }
  th, td { border: 1px solid #ddd; padding: 0.5em; text-align: left; }
  th { background: #f0f0f0; }
  .back { display: inline-block; margin-bottom: 1em; text-decoration: none; 
          background: #3498db; color: white; padding: 0.5em 1em; border-radius: 4px; }
</style>
</head>
<body>
<a href="/files/" class="back">← 返回媒体列表</a>
<h1>${path.basename(resolved)}</h1>
<hr>
<pre style="white-space: pre-wrap;">${data.replace(/</g, '&lt;').replace(/>/g, '&gt;')}</pre>
</body></html>`;
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end(html);
      } else {
        res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
        res.end(data);
      }
    });
  }

  tryDir(0);
}

// ==================== HTTP 反向代理 ====================

function proxyHttpRequest(clientReq, clientRes) {
  const options = {
    hostname: BFF_HOST,
    port: BFF_PORT,
    path: clientReq.url,
    method: clientReq.method,
    headers: { ...clientReq.headers, host: `${BFF_HOST}:${BFF_PORT}` },
  };

  const bffReq = http.request(options, (bffRes) => {
    clientRes.writeHead(bffRes.statusCode, bffRes.headers);
    bffRes.pipe(clientRes, { end: true });
  });

  bffReq.on('error', () => {
    if (!clientRes.headersSent) {
      clientRes.writeHead(502, { 'Content-Type': 'text/plain' });
      clientRes.end('Bad Gateway: BFF server unavailable');
    }
  });

  clientReq.pipe(bffReq, { end: true });
}

// ==================== WebSocket 反向代理 ====================

function proxyWebSocket(clientReq, clientSocket, clientHead) {
  const bffSocket = net.connect(BFF_PORT, BFF_HOST, () => {
    let rawRequest = `${clientReq.method} ${clientReq.url} HTTP/${clientReq.httpVersion}\r\n`;
    for (let i = 0; i < clientReq.rawHeaders.length; i += 2) {
      rawRequest += `${clientReq.rawHeaders[i]}: ${clientReq.rawHeaders[i + 1]}\r\n`;
    }
    rawRequest += '\r\n';

    bffSocket.write(rawRequest);
    if (clientHead && clientHead.length) {
      bffSocket.write(clientHead);
    }

    bffSocket.pipe(clientSocket);
    clientSocket.pipe(bffSocket);
  });

  const cleanup = () => {
    try { bffSocket.destroy(); } catch (_) {}
    try { clientSocket.destroy(); } catch (_) {}
  };

  bffSocket.on('error', cleanup);
  clientSocket.on('error', cleanup);
  clientSocket.on('close', () => { try { bffSocket.end(); } catch (_) {} });
  bffSocket.on('close', () => { try { clientSocket.end(); } catch (_) {} });
}

// ==================== 历史记录服务 ====================

function serveHistory(req, res, query) {
  const days = parseInt(query.days) || 10;
  const cutoff = Date.now() - (days * 24 * 60 * 60 * 1000);

  fs.readdir(SESSIONS_DIR, { withFileTypes: true }, (err, entries) => {
    if (err) {
      res.writeHead(500, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end('<h1>错误</h1><p>无法读取会话目录</p>');
      return;
    }

    const sessions = [];
    let pending = 0;

    entries.forEach(entry => {
      if (!entry.isFile() || !entry.name.endsWith('.json')) return;

      pending++;
      const filePath = path.join(SESSIONS_DIR, entry.name);

      fs.readFile(filePath, 'utf8', (err, data) => {
        if (!err) {
          try {
            const session = JSON.parse(data);
            const mtime = fs.statSync(filePath).mtimeMs;
            const msgCount = Array.isArray(session.messages) ? session.messages.length : 0;

            // 过滤：只显示有真实消息的会话，且在规定时间内
            if (mtime >= cutoff && msgCount > 0) {
              sessions.push({
                // 使用文件名（不含扩展名）作为 ID，确保与磁盘文件一一对应
                id: entry.name.replace('.json', ''),
                name: session.name || session.title || '未命名对话',
                model: session.model || session.original_model || '未知模型',
                platform: session.platform || session.channel || 'webchat',
                messages: msgCount,
                updated: new Date(mtime).toLocaleString('zh-CN'),
                mtime: mtime
              });
            }
          } catch (e) {}
        }

        pending--;
        if (pending === 0) {
          // 按时间倒序
          sessions.sort((a, b) => b.mtime - a.mtime);

          const html = buildHistoryHtml(sessions, days);
          res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
          res.end(html);
        }
      });
    });

    if (pending === 0) {
      const html = buildHistoryHtml([], days);
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(html);
    }
  });
}

function serveHistoryDetail(req, res, sessionId) {
  // 首先尝试直接匹配文件名
  const directPath = path.join(SESSIONS_DIR, `${sessionId}.json`);

  fs.readFile(directPath, 'utf8', (err, data) => {
    if (!err) {
      try {
        const session = JSON.parse(data);
        const html = buildHistoryDetailHtml(session, sessionId);
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end(html);
        return;
      } catch (e) {
        res.writeHead(500, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end('<h1>错误</h1><p>无法解析会话数据</p>');
        return;
      }
    }

    // 直接匹配失败：扫描目录，查找包含该 session_id / id 的文件
    fs.readdir(SESSIONS_DIR, { withFileTypes: true }, (readErr, entries) => {
      if (readErr) {
        res.writeHead(500, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end('<h1>错误</h1><p>无法读取会话目录</p>');
        return;
      }

      const jsonFiles = entries
        .filter(e => e.isFile() && e.name.endsWith('.json'))
        .map(e => e.name);

      let checked = 0;
      let found = false;

      if (jsonFiles.length === 0) {
        res.writeHead(404, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end('<h1>404</h1><p>会话不存在</p>');
        return;
      }

      jsonFiles.forEach(fileName => {
        const fp = path.join(SESSIONS_DIR, fileName);
        fs.readFile(fp, 'utf8', (readFileErr, fileData) => {
          if (found) return; // 已找到，忽略后续结果

          checked++;

          if (!readFileErr) {
            try {
              const session = JSON.parse(fileData);
              if (
                session.session_id === sessionId ||
                session.id === sessionId ||
                fileName.replace('.json', '') === sessionId
              ) {
                found = true;
                const html = buildHistoryDetailHtml(session, sessionId);
                res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
                res.end(html);
                return;
              }
            } catch (e) {}
          }

          if (checked === jsonFiles.length && !found) {
            res.writeHead(404, { 'Content-Type': 'text/html; charset=utf-8' });
            res.end('<h1>404</h1><p>会话不存在</p>');
          }
        });
      });
    });
  });
}

function buildHistoryDetailHtml(session, sessionId) {
  const messages = (session.messages || []).map((msg, index) => {
    const role = msg.role || 'unknown';
    const content = msg.content || '';
    const isUser = role === 'user';

    // Convert markdown image/media references to HTML
    let renderedContent = content
      .replace(/!\[([^\]]*)\]\(([^)]+)\)/g, (match, alt, src) => {
        const fileName = path.basename(src);
        const ext = path.extname(fileName).toLowerCase();
        const url = src.startsWith('/') ? src : `/files/${encodeURIComponent(src)}`;

        if (['.png','.jpg','.jpeg','.gif','.webp','.svg','.bmp'].includes(ext)) {
          return `<img src="${url}" alt="${alt}" style="max-width:100%;border-radius:8px;margin:8px 0;" />`;
        } else if (['.mp4','.avi','.mov','.mkv','.webm','.m4v','.3gp'].includes(ext)) {
          return `<video controls width="100%" style="max-width:600px;border-radius:8px;margin:8px 0;">
            <source src="${url}" type="${getMimeType(fileName)}">
            您的浏览器不支持视频播放
          </video>`;
        } else if (['.mp3','.wav','.aac','.ogg','.flac','.m4a','.wma'].includes(ext)) {
          return `<audio controls style="width:100%;max-width:400px;margin:8px 0;">
            <source src="${url}" type="${getMimeType(fileName)}">
            您的浏览器不支持音频播放
          </audio>`;
        } else {
          return `<a href="${url}" target="_blank" style="color:#7eb8da;">📎 ${alt || fileName}</a>`;
        }
      })
      .replace(/(https?:\/\/[^\s<]+)/g, '<a href="$1" target="_blank" style="color:#7eb8da;">$1</a>')
      .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
      .replace(/\*([^*]+)\*/g, '<em>$1</em>')
      .replace(/\n/g, '<br>');

    return `<div class="message ${isUser ? 'user' : 'assistant'}">
      <div class="message-header">
        <span class="role-badge ${isUser ? 'role-user' : 'role-assistant'}">${isUser ? '👤 用户' : '🤖 助手'}</span>
        <span class="msg-index">#${index + 1}</span>
      </div>
      <div class="message-content">${renderedContent}</div>
    </div>`;
  }).join('');

  return `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${session.name || '对话详情'} - Hermes Agent</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
         background: #0f0f23; color: #e0e0e0; padding: 2em; min-height: 100vh; }
  h1 { color: #7eb8da; margin-bottom: 0.3em; }
  .back-link { color: #7eb8da; text-decoration: none; margin-bottom: 1em; display: inline-block; }
  .back-link:hover { text-decoration: underline; }

  .session-meta { background: #1a1a2e; padding: 1em; border-radius: 8px; margin-bottom: 1.5em; }
  .meta-row { margin: 0.3em 0; color: #aaa; font-size: 0.9em; }
  .meta-label { color: #7eb8da; font-weight: 500; }

  .messages { max-width: 900px; }
  .message { margin-bottom: 1.5em; padding: 1em; border-radius: 8px; }
  .message.user { background: #1a2332; border-left: 3px solid #2196F3; }
  .message.assistant { background: #1a2e1a; border-left: 3px solid #4CAF50; }

  .message-header { display: flex; justify-content: space-between; margin-bottom: 0.5em; }
  .role-badge { font-size: 0.85em; font-weight: 600; padding: 0.2em 0.6em; border-radius: 4px; }
  .role-user { background: #2196F3; color: white; }
  .role-assistant { background: #4CAF50; color: white; }
  .msg-index { color: #666; font-size: 0.8em; }

  .message-content { line-height: 1.6; }
  .message-content img { max-width: 100%; border-radius: 8px; margin: 8px 0; }
  .message-content video { max-width: 100%; border-radius: 8px; margin: 8px 0; }
  .message-content audio { width: 100%; max-width: 400px; margin: 8px 0; }
</style>
</head>
<body>
<a href="/history/" class="back-link">← 返回历史记录</a>
<h1>${session.name || '未命名对话'}</h1>

<div class="session-meta">
  <div class="meta-row"><span class="meta-label">ID:</span> ${sessionId}</div>
  <div class="meta-row"><span class="meta-label">模型:</span> ${session.model || session.original_model || '未知'}</div>
  <div class="meta-row"><span class="meta-label">渠道:</span> ${session.platform || session.channel || 'webchat'}</div>
  <div class="meta-row"><span class="meta-label">消息数:</span> ${session.messages ? session.messages.length : 0}</div>
</div>

<div class="messages">
  ${messages || '<p style="color:#666;text-align:center;padding:2em;">暂无消息</p>'}
</div>

</body></html>`;
}

function buildHistoryHtml(sessions, days) {
  const rows = sessions.map(s => {
    return `<tr>
      <td><a href="/history/${s.id}" style="color:#7eb8da;text-decoration:none;">${s.name}</a></td>
      <td><span class="badge platform-${s.platform}">${s.platform}</span></td>
      <td>${s.model}</td>
      <td>${s.messages}</td>
      <td>${s.updated}</td>
    </tr>`;
  }).join('');
  
  return `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>📜 历史记录 - Hermes Agent</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
         background: #0f0f23; color: #e0e0e0; padding: 2em; min-height: 100vh; }
  h1 { color: #7eb8da; margin-bottom: 0.5em; }
  .subtitle { color: #888; font-size: 0.9em; margin-bottom: 1.5em; }
  
  table { width: 100%; border-collapse: collapse; margin-top: 1em; }
  th { background: #1a1a2e; color: #7eb8da; padding: 0.8em; text-align: left; 
       font-weight: 600; border-bottom: 2px solid #7eb8da; }
  td { padding: 0.8em; border-bottom: 1px solid #333; }
  tr:hover { background: #1a1a2e; }
  
  .badge { display: inline-block; padding: 0.2em 0.6em; border-radius: 4px; 
           font-size: 0.85em; font-weight: 500; }
  .platform-webchat { background: #4CAF50; color: white; }
  .platform-wechat { background: #07C160; color: white; }
  .platform-discord { background: #5865F2; color: white; }
  .platform-telegram { background: #0088cc; color: white; }
  .platform-slack { background: #E01E5A; color: white; }
  .platform-default { background: #666; color: white; }
  
  .empty { text-align: center; padding: 3em; color: #666; }
  .filter-bar { margin-bottom: 1em; }
  .filter-bar a { color: #7eb8da; text-decoration: none; margin-right: 1em; }
  .filter-bar a.active { font-weight: bold; border-bottom: 2px solid #7eb8da; }
</style>
</head>
<body>
<h1>📜 对话历史记录</h1>
<p class="subtitle">显示近 ${days} 天的所有渠道对话记录（共 ${sessions.length} 条）</p>

<div class="filter-bar">
  <a href="?days=1" class="${days === 1 ? 'active' : ''}">1天</a>
  <a href="?days=7" class="${days === 7 ? 'active' : ''}">7天</a>
  <a href="?days=10" class="${days === 10 ? 'active' : ''}">10天</a>
  <a href="?days=30" class="${days === 30 ? 'active' : ''}">30天</a>
</div>

${sessions.length === 0 ? 
  '<div class="empty"><p>暂无历史记录</p></div>' :
  `<table>
    <thead>
      <tr>
        <th>对话名称</th>
        <th>渠道</th>
        <th>模型</th>
        <th>消息数</th>
        <th>更新时间</th>
      </tr>
    </thead>
    <tbody>${rows}</tbody>
  </table>`}

</body></html>`;
}

// ==================== 主服务器 ====================

const server = http.createServer((clientReq, clientRes) => {
  // 解析 URL 和查询参数
  const urlParts = clientReq.url.split('?');
  const pathname = urlParts[0];
  const query = {};
  if (urlParts[1]) {
    urlParts[1].split('&').forEach(pair => {
      const [k, v] = pair.split('=').map(decodeURIComponent);
      query[k] = v;
    });
  }

  // 媒体文件列表服务
  if (pathname === '/files' || pathname === '/files/') {
    return serveImageList(clientReq, clientRes, query);
  }
  // 媒体文件服务
  if (pathname.startsWith('/files/')) {
    return serveImage(pathname, query, clientRes);
  }
  // 历史记录服务
  if (pathname.startsWith('/history/') && pathname.length > 9) {
    const sessionId = pathname.slice(9);
    return serveHistoryDetail(clientReq, clientRes, sessionId);
  }
  if (pathname === '/history' || pathname === '/history/') {
    return serveHistory(clientReq, clientRes, query);
  }

  // 其他请求透传给 BFF
  proxyHttpRequest(clientReq, clientRes);
});

// WebSocket 透传
server.on('upgrade', proxyWebSocket);

server.listen(LISTEN_PORT, () => {
  console.log(`📁 Media proxy listening on :${LISTEN_PORT}`);
  console.log(`🌐 Open: http://localhost:${LISTEN_PORT}/files/`);
  console.log(`tunnel: http://${BFF_HOST}:${BFF_PORT}`);
});
