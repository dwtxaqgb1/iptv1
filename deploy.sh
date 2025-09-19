#!/bin/bash
set -e

# 项目名称
PROJECT_NAME="auto-save-link"
# 部署目录
DEPLOY_DIR="./${PROJECT_NAME}"
# 目标存储目录
TARGET_DIR="/vol2/1000/www"

# 创建目标存储目录
echo "创建目标存储目录: $TARGET_DIR"
sudo mkdir -p "$TARGET_DIR"
sudo chmod 777 "$TARGET_DIR"  # 简化权限设置，实际环境可根据需要调整

# 创建项目目录
echo "创建项目目录: $DEPLOY_DIR"
mkdir -p "$DEPLOY_DIR/app/templates"

# 创建 docker-compose.yml
echo "生成 docker-compose.yml"
cat > "$DEPLOY_DIR/docker-compose.yml" << 'EOF'
version: '3.8'

services:
  auto-save-link:
    build: ./app
    container_name: auto-save-link
    restart: always
    ports:
      - "5000:5000"
    volumes:
      - /vol2/1000/www:/app/downloads
      - ./app/data:/app/data
    environment:
      - TZ=Asia/Shanghai
      - FLASK_APP=app.py
      - FLASK_ENV=production
EOF

# 创建 Dockerfile
echo "生成 Dockerfile"
cat > "$DEPLOY_DIR/app/Dockerfile" << 'EOF'
FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

RUN mkdir -p /app/downloads /app/data

EXPOSE 5000

CMD ["gunicorn", "--bind", "0.0.0.0:5000", "app:app", "--workers", "2"]
EOF

# 创建 requirements.txt
echo "生成 requirements.txt"
cat > "$DEPLOY_DIR/app/requirements.txt" << 'EOF'
flask==2.3.3
apscheduler==3.10.4
requests==2.31.0
sqlalchemy==2.0.23
gunicorn==21.2.0
python-dotenv==1.0.0
EOF

# 创建 app.py
echo "生成 app.py"
cat > "$DEPLOY_DIR/app/app.py" << 'EOF'
from flask import Flask, render_template, request, redirect, flash, url_for
from flask_sqlalchemy import SQLAlchemy
from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.cron import CronTrigger
import requests
import os
from datetime import datetime

app = Flask(__name__)
app.secret_key = "auto-save-link-secret-key"
app.config['SQLALCHEMY_DATABASE_URI'] = f"sqlite:////app/data/tasks.db"
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
db = SQLAlchemy(app)

class DownloadTask(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    task_name = db.Column(db.String(100), nullable=False)
    target_url = db.Column(db.String(500), nullable=False)
    save_filename = db.Column(db.String(200), nullable=False)
    cron_expr = db.Column(db.String(50), nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    last_run = db.Column(db.DateTime, nullable=True)
    status = db.Column(db.String(20), default="active")

    def __repr__(self):
        return f"<Task {self.task_name}>"

scheduler = BackgroundScheduler(timezone="Asia/Shanghai")
DOWNLOAD_DIR = "/app/downloads"

def download_file(task_id):
    task = DownloadTask.query.get(task_id)
    if not task or task.status != "active":
        return
    
    try:
        current_date = datetime.now().strftime("%Y%m%d")
        final_filename = task.save_filename.replace("{date}", current_date)
        save_path = os.path.join(DOWNLOAD_DIR, final_filename)
        
        response = requests.get(task.target_url, stream=True, timeout=30)
        response.raise_for_status()
        
        with open(save_path, "wb") as f:
            for chunk in response.iter_content(chunk_size=8192):
                f.write(chunk)
        
        task.last_run = datetime.now()
        db.session.commit()
        print(f"成功下载：{task.task_name} -> {save_path}")
    
    except Exception as e:
        print(f"下载失败 {task.task_name}：{str(e)}")

def add_task_to_scheduler(task):
    if task.status != "active":
        return
    cron_parts = task.cron_expr.split()
    if len(cron_parts) != 5:
        print(f"无效 cron 表达式：{task.cron_expr}")
        return
    
    trigger = CronTrigger(
        minute=cron_parts[0],
        hour=cron_parts[1],
        day=cron_parts[2],
        month=cron_parts[3],
        day_of_week=cron_parts[4],
        timezone="Asia/Shanghai"
    )
    scheduler.add_job(
        func=download_file,
        trigger=trigger,
        id=str(task.id),
        args=[task.id],
        replace_existing=True
    )

def load_tasks_to_scheduler():
    scheduler.remove_all_jobs()
    active_tasks = DownloadTask.query.filter_by(status="active").all()
    for task in active_tasks:
        add_task_to_scheduler(task)
    print(f"已加载 {len(active_tasks)} 个活跃任务到调度器")

@app.route("/")
def index():
    tasks = DownloadTask.query.order_by(DownloadTask.id.desc()).all()
    return render_template("index.html", tasks=tasks)

@app.route("/add", methods=["GET", "POST"])
def add_task():
    if request.method == "POST":
        task_name = request.form.get("task_name")
        target_url = request.form.get("target_url")
        save_filename = request.form.get("save_filename")
        cron_expr = request.form.get("cron_expr")
        status = request.form.get("status", "active")
        
        if not all([task_name, target_url, save_filename, cron_expr]):
            flash("所有字段不能为空！", "danger")
            return redirect(url_for("add_task"))
        
        new_task = DownloadTask(
            task_name=task_name,
            target_url=target_url,
            save_filename=save_filename,
            cron_expr=cron_expr,
            status=status
        )
        db.session.add(new_task)
        db.session.commit()
        
        add_task_to_scheduler(new_task)
        flash(f"任务「{task_name}」添加成功！", "success")
        return redirect(url_for("index"))
    
    return render_template("add_task.html")

@app.route("/edit/<int:task_id>", methods=["GET", "POST"])
def edit_task(task_id):
    task = DownloadTask.query.get_or_404(task_id)
    if request.method == "POST":
        task.task_name = request.form.get("task_name")
        task.target_url = request.form.get("target_url")
        task.save_filename = request.form.get("save_filename")
        task.cron_expr = request.form.get("cron_expr")
        task.status = request.form.get("status", "active")
        
        db.session.commit()
        add_task_to_scheduler(task)
        flash(f"任务「{task.task_name}」编辑成功！", "success")
        return redirect(url_for("index"))
    
    return render_template("edit_task.html", task=task)

@app.route("/delete/<int:task_id>", methods=["POST"])
def delete_task(task_id):
    task = DownloadTask.query.get_or_404(task_id)
    scheduler.remove_job(str(task_id))
    db.session.delete(task)
    db.session.commit()
    flash(f"任务「{task.task_name}」已删除！", "success")
    return redirect(url_for("index"))

@app.route("/run-now/<int:task_id>")
def run_now(task_id):
    download_file(task_id)
    flash("已触发任务立即执行，可查看日志确认结果！", "info")
    return redirect(url_for("index"))

with app.app_context():
    db.create_all()
    load_tasks_to_scheduler()
    scheduler.start()

import atexit
atexit.register(lambda: scheduler.shutdown())

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)
EOF

# 创建 index.html
echo "生成 index.html"
cat > "$DEPLOY_DIR/app/templates/index.html" << 'EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <title>自动保存链接文件</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
</head>
<body class="container mt-4">
    <h1 class="mb-4">自动保存链接管理</h1>
    
    {% with messages = get_flashed_messages(with_categories=true) %}
        {% if messages %}
            {% for category, message in messages %}
                <div class="alert alert-{{ category }} alert-dismissible fade show" role="alert">
                    {{ message }}
                    <button type="button" class="btn-close" data-bs-dismiss="alert" aria-label="Close"></button>
                </div>
            {% endfor %}
        {% endif %}
    {% endwith %}

    <a href="{{ url_for('add_task') }}" class="btn btn-primary mb-3">添加新任务</a>

    <table class="table table-bordered table-hover">
        <thead class="table-light">
            <tr>
                <th>ID</th>
                <th>任务名称</th>
                <th>目标链接</th>
                <th>保存文件名</th>
                <th>定时规则（cron）</th>
                <th>状态</th>
                <th>最后运行时间</th>
                <th>操作</th>
            </tr>
        </thead>
        <tbody>
            {% for task in tasks %}
            <tr>
                <td>{{ task.id }}</td>
                <td>{{ task.task_name }}</td>
                <td><a href="{{ task.target_url }}" target="_blank" class="text-primary">{{ task.target_url[:50] }}...</a></td>
                <td>{{ task.save_filename }}</td>
                <td>{{ task.cron_expr }} <small class="text-muted">(分 时 日 月 周)</small></td>
                <td>
                    {% if task.status == "active" %}
                        <span class="badge bg-success">活跃</span>
                    {% else %}
                        <span class="badge bg-secondary">禁用</span>
                    {% endif %}
                </td>
                <td>{{ task.last_run.strftime("%Y-%m-%d %H:%M") if task.last_run else "未运行" }}</td>
                <td>
                    <a href="{{ url_for('edit_task', task_id=task.id) }}" class="btn btn-sm btn-warning">编辑</a>
                    <a href="{{ url_for('run_now', task_id=task.id) }}" class="btn btn-sm btn-info">立即执行</a>
                    <form action="{{ url_for('delete_task', task_id=task.id) }}" method="post" class="d-inline">
                        <button type="submit" class="btn btn-sm btn-danger" onclick="return confirm('确定删除？')">删除</button>
                    </form>
                </td>
            </tr>
            {% else %}
            <tr>
                <td colspan="8" class="text-center text-muted">暂无任务，点击“添加新任务”创建</td>
            </tr>
            {% endfor %}
        </tbody>
    </table>

    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
</body>
</html>
EOF

# 创建 add_task.html
echo "生成 add_task.html"
cat > "$DEPLOY_DIR/app/templates/add_task.html" << 'EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <title>添加新任务</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
</head>
<body class="container mt-4">
    <h1 class="mb-4">添加新任务</h1>
    <a href="{{ url_for('index') }}" class="btn btn-secondary mb-3">返回任务列表</a>

    <form method="post" class="col-md-8">
        <div class="mb-3">
            <label for="task_name" class="form-label">任务名称</label>
            <input type="text" class="form-control" id="task_name" name="task_name" placeholder="如：每日 m3u 保存" required>
        </div>
        <div class="mb-3">
            <label for="target_url" class="form-label">目标链接</label>
            <input type="url" class="form-control" id="target_url" name="target_url" placeholder="如：http://www.ipxxx.com/1.m3u" required>
        </div>
        <div class="mb-3">
            <label for="save_filename" class="form-label">保存文件名</label>
            <input type="text" class="form-control" id="save_filename" name="save_filename" value="1_{date}.m3u" required>
            <div class="form-text">支持 {date} 占位符（自动替换为当前日期，如 1_20240520.m3u）</div>
        </div>
        <div class="mb-3">
            <label for="cron_expr" class="form-label">定时规则（cron 表达式）</label>
            <input type="text" class="form-control" id="cron_expr" name="cron_expr" value="0 2 * * *" required>
            <div class="form-text">格式：分 时 日 月 周（例：0 2 * * * = 每天凌晨 2 点）</div>
        </div>
        <div class="mb-3">
            <label for="status" class="form-label">任务状态</label>
            <select class="form-select" id="status" name="status" required>
                <option value="active" selected>活跃（定时执行）</option>
                <option value="inactive">禁用（暂不执行）</option>
            </select>
        </div>
        <button type="submit" class="btn btn-primary">提交</button>
    </form>

    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
</body>
</html>
EOF

# 创建 edit_task.html
echo "生成 edit_task.html"
cat > "$DEPLOY_DIR/app/templates/edit_task.html" << 'EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <title>编辑任务</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
</head>
<body class="container mt-4">
    <h1 class="mb-4">编辑任务：{{ task.task_name }}</h1>
    <a href="{{ url_for('index') }}" class="btn btn-secondary mb-3">返回任务列表</a>

    <form method="post" class="col-md-8">
        <div class="mb-3">
            <label for="task_name" class="form-label">任务名称</label>
            <input type="text" class="form-control" id="task_name" name="task_name" value="{{ task.task_name }}" required>
        </div>
        <div class="mb-3">
            <label for="target_url" class="form-label">目标链接</label>
            <input type="url" class="form-control" id="target_url" name="target_url" value="{{ task.target_url }}" required>
        </div>
        <div class="mb-3">
            <label for="save_filename" class="form-label">保存文件名</label>
            <input type="text" class="form-control" id="save_filename" name="save_filename" value="{{ task.save_filename }}" required>
            <div class="form-text">支持 {date} 占位符（自动替换为当前日期，如 1_20240520.m3u）</div>
        </div>
        <div class="mb-3">
            <label for="cron_expr" class="form-label">定时规则（cron 表达式）</label>
            <input type="text" class="form-control" id="cron_expr" name="cron_expr" value="{{ task.cron_expr }}" required>
            <div class="form-text">格式：分 时 日 月 周（例：0 2 * * * = 每天凌晨 2 点）</div>
        </div>
        <div class="mb-3">
            <label for="status" class="form-label">任务状态</label>
            <select class="form-select" id="status" name="status" required>
                <option value="active" {% if task.status == "active" %}selected{% endif %}>活跃（定时执行）</option>
                <option value="inactive" {% if task.status == "inactive" %}selected{% endif %}>禁用（暂不执行）</option>
            </select>
        </div>
        <button type="submit" class="btn btn-primary">保存修改</button>
    </form>

    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
</body>
</html>
EOF

# 启动服务
echo "启动服务..."
cd "$DEPLOY_DIR" && docker-compose up -d --build

# 显示部署结果
echo "部署完成！"
echo "请访问 http://localhost:5000 进行配置"
echo "文件将保存到 $TARGET_DIR 目录"
