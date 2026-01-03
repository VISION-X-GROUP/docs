import os
import sqlite3
import threading
import time
import json
import logging
from datetime import datetime, timedelta
from typing import Dict, List, Optional, Tuple
from dataclasses import dataclass, asdict
from enum import Enum

from flask import Flask, render_template, request, redirect, url_for, session, jsonify, send_file
from flask_socketio import SocketIO, emit
from werkzeug.security import generate_password_hash, check_password_hash
from fpdf import FPDF
import openai
from dotenv import load_dotenv

# تحميل متغيرات البيئة
load_dotenv()

# إعداد التسجيل
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('company.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

app = Flask(__name__)
app.secret_key = os.environ.get('SECRET_KEY', os.urandom(24))
socketio = SocketIO(app, cors_allowed_origins="*")

# ===========================================
# تعريفات الأنواع والمتغيرات
# ===========================================

class TaskStatus(Enum):
    PENDING = "pending"
    IN_PROGRESS = "in_progress"
    COMPLETED = "completed"
    FAILED = "failed"

class BotStatus(Enum):
    AVAILABLE = "available"
    BUSY = "busy"
    TRAINING = "training"
    OFFLINE = "offline"

@dataclass
class Task:
    id: int
    dept: str
    description: str
    skill_required: str
    priority: int  # 1-5 (5 هو الأعلى)
    estimated_time: int  # بالدقائق
    assigned_to: Optional[int]
    status: TaskStatus
    created_at: datetime
    completed_at: Optional[datetime]

@dataclass
class PerformanceMetrics:
    bot_id: int
    task_id: int
    efficiency_score: float  # 0-100%
    completion_time: int  # بالثواني
    accuracy_score: float  # 0-100%
    learning_gain: float  # 0-1
    timestamp: datetime

# ===========================================
# قاعدة البيانات المحسنة
# ===========================================

def init_db():
    """تهيئة قاعدة البيانات مع الجداول المحسنة"""
    conn = sqlite3.connect('company.db')
    c = conn.cursor()
    
    # جدول الموظفين (البوتات)
    c.execute('''CREATE TABLE IF NOT EXISTS employees
                (id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                dept TEXT NOT NULL,
                skills TEXT NOT NULL,
                status TEXT DEFAULT 'active',
                experience_level INTEGER DEFAULT 1,
                total_tasks_completed INTEGER DEFAULT 0,
                avg_efficiency REAL DEFAULT 0.0,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                last_active TIMESTAMP DEFAULT CURRENT_TIMESTAMP)''')
    
    # جدول المهام المحسن
    c.execute('''CREATE TABLE IF NOT EXISTS tasks
                (id INTEGER PRIMARY KEY AUTOINCREMENT,
                dept TEXT NOT NULL,
                task_description TEXT NOT NULL,
                skill_required TEXT NOT NULL,
                priority INTEGER DEFAULT 3,
                estimated_time INTEGER DEFAULT 60,
                assigned_to INTEGER,
                status TEXT DEFAULT 'pending',
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                started_at TIMESTAMP,
                completed_at TIMESTAMP,
                result_data TEXT,
                FOREIGN KEY(assigned_to) REFERENCES employees(id))''')
    
    # جدول الأداء والتقارير
    c.execute('''CREATE TABLE IF NOT EXISTS performance
                (id INTEGER PRIMARY KEY AUTOINCREMENT,
                bot_id INTEGER NOT NULL,
                task_id INTEGER NOT NULL,
                efficiency_score REAL DEFAULT 0.0,
                completion_time INTEGER DEFAULT 0,
                accuracy_score REAL DEFAULT 0.0,
                learning_gain REAL DEFAULT 0.0,
                timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY(bot_id) REFERENCES employees(id),
                FOREIGN KEY(task_id) REFERENCES tasks(id))''')
    
    # جدول الأهداف
    c.execute('''CREATE TABLE IF NOT EXISTS goals
                (id INTEGER PRIMARY KEY AUTOINCREMENT,
                department TEXT NOT NULL,
                goal_text TEXT NOT NULL,
                priority INTEGER DEFAULT 3,
                status TEXT DEFAULT 'active',
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                deadline TIMESTAMP,
                completed_at TIMESTAMP)''')
    
    # جدول التعلم الآلي
    c.execute('''CREATE TABLE IF NOT EXISTS learning_data
                (id INTEGER PRIMARY KEY AUTOINCREMENT,
                bot_id INTEGER NOT NULL,
                task_type TEXT NOT NULL,
                success_count INTEGER DEFAULT 0,
                failure_count INTEGER DEFAULT 0,
                avg_completion_time REAL DEFAULT 0.0,
                last_updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY(bot_id) REFERENCES employees(id))''')
    
    # إضافة بيانات أولية إذا كانت الجداول فارغة
    if not c.execute('SELECT 1 FROM employees LIMIT 1').fetchone():
        initial_bots = [
            ('بوت التسويق الذكي 1', 'marketing', 'تحليل السوق,إعلانات,وسائل التواصل الاجتماعي,SEO', 3),
            ('بوت التسويق الذكي 2', 'marketing', 'إعلانات,تحليلات,كتابة محتوى,إدارة الحملات', 2),
            ('بوت التطوير المتقدم 1', 'development', 'بايثون,فلاسك,React,قواعد البيانات', 4),
            ('بوت التطوير المتقدم 2', 'development', 'جافاسكريبت,HTML,CSS,Node.js', 3),
            ('بوت الماليات الذكي', 'finance', 'تحليل مالي,المحاسبة,التقارير,التنبؤ', 3),
            ('بوت الموارد البشرية الذكي', 'hr', 'التوظيف,التدريب,إدارة الأداء,التواصل', 2),
            ('بوت العمليات المتقدم', 'operations', 'إدارة العمليات,اللوجستيات,التخطيط,المراقبة', 3),
            ('بوت التحليلات الذكي', 'analytics', 'تحليل البيانات,التقارير,التصور,التنبؤ', 4)
        ]
        
        for name, dept, skills, level in initial_bots:
            c.execute('''INSERT INTO employees (name, dept, skills, experience_level) 
                        VALUES (?, ?, ?, ?)''', (name, dept, skills, level))
        
        # إضافة مهام أولية
        sample_tasks = [
            ('marketing', 'تحليل أداء الحملة التسويقية الأخيرة', 'تحليل السوق', 4, 120),
            ('development', 'تطوير واجهة جديدة لنظام الإدارة', 'بايثون', 5, 240),
            ('finance', 'إعداد تقرير الربع الأول', 'تحليل مالي', 3, 180),
            ('analytics', 'تحليل بيانات العملاء لتحديد الاتجاهات', 'تحليل البيانات', 4, 150)
        ]
        
        for dept, desc, skill, priority, time in sample_tasks:
            c.execute('''INSERT INTO tasks (dept, task_description, skill_required, priority, estimated_time)
                        VALUES (?, ?, ?, ?, ?)''', (dept, desc, skill, priority, time))
    
    conn.commit()
    conn.close()
    logger.info("تم تهيئة قاعدة البيانات بنجاح")

def get_db():
    """الحصول على اتصال بقاعدة البيانات"""
    conn = sqlite3.connect('company.db')
    conn.row_factory = sqlite3.Row
    return conn

# ===========================================
# نظام إدارة المهام الذكي
# ===========================================

class SmartTaskAssigner:
    """نظام ذكي لتعيين المهام"""
    
    def __init__(self):
        self.task_queue = []
        self.learning_data = {}
        logger.info("تم تهيئة SmartTaskAssigner")
    
    def assign_based_on_skills(self, task_data: Dict) -> Optional[int]:
        """تعيين المهام بناءً على مهارات البوت"""
        try:
            conn = get_db()
            c = conn.cursor()
            
            # البحث عن البوتات المناسبة
            query = '''SELECT * FROM employees 
                      WHERE dept = ? 
                      AND skills LIKE ? 
                      AND status = 'active'
                      ORDER BY experience_level DESC, avg_efficiency DESC'''
            
            c.execute(query, (task_data['dept'], f"%{task_data['skill_required']}%"))
            bots = c.fetchall()
            
            if bots:
                # اختيار أفضل بوت
                best_bot = self.calculate_best_fit(bots, task_data)
                
                if best_bot:
                    # تحديث المهمة
                    c.execute('''UPDATE tasks SET assigned_to = ?, status = 'in_progress', started_at = ?
                                WHERE id = ?''', 
                            (best_bot['id'], datetime.now(), task_data.get('task_id')))
                    
                    # تحديث حالة البوت
                    c.execute('''UPDATE employees SET status = 'busy', last_active = ?
                                WHERE id = ?''', 
                            (datetime.now(), best_bot['id']))
                    
                    conn.commit()
                    
                    # إرسال تحديث عبر WebSocket
                    socketio.emit('task_assigned', {
                        'task_id': task_data.get('task_id'),
                        'bot_id': best_bot['id'],
                        'bot_name': best_bot['name'],
                        'timestamp': datetime.now().isoformat()
                    })
                    
                    logger.info(f"تم تعيين المهمة {task_data.get('task_id')} إلى البوت {best_bot['name']}")
                    return best_bot['id']
            
            conn.close()
            return None
            
        except Exception as e:
            logger.error(f"خطأ في تعيين المهمة: {str(e)}")
            return None
    
    def calculate_best_fit(self, bots, task_data: Dict) -> Optional[sqlite3.Row]:
        """حساب أفضل بوت للمهمة"""
        try:
            scores = []
            
            for bot in bots:
                score = 0
                
                # 1. المهارات المطابقة (40%)
                bot_skills = bot['skills'].split(',')
                required_skills = task_data.get('skill_required', '').split(',')
                matching_skills = set(bot_skills) & set(required_skills)
                skill_score = (len(matching_skills) / max(len(required_skills), 1)) * 40
                score += skill_score
                
                # 2. الخبرة (25%)
                experience_score = min(bot['experience_level'] * 5, 25)
                score += experience_score
                
                # 3. الكفاءة (20%)
                efficiency_score = (bot['avg_efficiency'] / 100) * 20
                score += efficiency_score
                
                # 4. الوقت المتاح (15%)
                conn = get_db()
                c = conn.cursor()
                c.execute('SELECT COUNT(*) FROM tasks WHERE assigned_to = ? AND status = "in_progress"', 
                         (bot['id'],))
                current_tasks = c.fetchone()[0]
                conn.close()
                
                availability_score = max(0, 15 - (current_tasks * 3))
                score += availability_score
                
                # 5. التعلم السابق (إضافة إضافية)
                task_type = self.classify_task(task_data['task_description'])
                learning_bonus = self.get_learning_bonus(bot['id'], task_type)
                score += learning_bonus
                
                scores.append({
                    'bot': bot,
                    'score': score,
                    'details': {
                        'skill_score': skill_score,
                        'experience_score': experience_score,
                        'efficiency_score': efficiency_score,
                        'availability_score': availability_score,
                        'learning_bonus': learning_bonus
                    }
                })
            
            # اختيار البوت بأعلى درجة
            if scores:
                best = max(scores, key=lambda x: x['score'])
                logger.debug(f"Best bot selected: {best['bot']['name']} with score {best['score']}")
                return best['bot']
            
            return None
            
        except Exception as e:
            logger.error(f"خطأ في حساب أفضل بوت: {str(e)}")
            return None
    
    def classify_task(self, task_description: str) -> str:
        """تصنيف المهمة"""
        keywords = {
            'تحليل': 'analysis',
            'تطوير': 'development',
            'تسويق': 'marketing',
            'مبيعات': 'sales',
            'مالي': 'finance',
            'محتوى': 'content',
            'برمجة': 'programming',
            'بيانات': 'data',
            'تدريب': 'training',
            'إدارة': 'management'
        }
        
        for key, value in keywords.items():
            if key in task_description:
                return value
        return 'general'
    
    def get_learning_bonus(self, bot_id: int, task_type: str) -> float:
        """الحصول على مكافأة التعلم"""
        try:
            conn = get_db()
            c = conn.cursor()
            c.execute('''SELECT success_count, failure_count, avg_completion_time 
                        FROM learning_data 
                        WHERE bot_id = ? AND task_type = ?''', 
                     (bot_id, task_type))
            
            data = c.fetchone()
            conn.close()
            
            if data and data['success_count'] > 0:
                success_rate = data['success_count'] / (data['success_count'] + data['failure_count'] + 1)
                time_factor = max(0, 1 - (data['avg_completion_time'] / 3600))  # ساعة مرجعية
                return (success_rate * time_factor) * 10  # حتى 10 نقاط إضافية
            
            return 0.0
            
        except Exception as e:
            logger.error(f"خطأ في حساب مكافأة التعلم: {str(e)}")
            return 0.0

# ===========================================
# نظام التعلم الآلي البسيط
# ===========================================

class LearningBot:
    """بوت ذكي يتعلم من التجارب"""
    
    def __init__(self, bot_id: int):
        self.bot_id = bot_id
        self.learning_rate = 0.1
        self.experience = {}
        self.task_history = []
        logger.info(f"تم تهيئة LearningBot للبوت {bot_id}")
    
    def complete_task(self, task_id: int, task_description: str, completion_time: int, success: bool = True):
        """إكمال المهمة وتسجيل الخبرة"""
        try:
            # تصنيف المهمة
            task_type = self.classify_task(task_description)
            
            # تحديث بيانات التعلم
            conn = get_db()
            c = conn.cursor()
            
            # البحث عن سجل التعلم الحالي
            c.execute('SELECT * FROM learning_data WHERE bot_id = ? AND task_type = ?', 
                     (self.bot_id, task_type))
            existing = c.fetchone()
            
            if existing:
                # تحديث السجل الحالي
                new_success = existing['success_count'] + (1 if success else 0)
                new_failure = existing['failure_count'] + (0 if success else 1)
                new_avg_time = ((existing['avg_completion_time'] * existing['success_count']) + 
                              completion_time) / (new_success + 1e-6)
                
                c.execute('''UPDATE learning_data 
                            SET success_count = ?, failure_count = ?, avg_completion_time = ?, last_updated = ?
                            WHERE bot_id = ? AND task_type = ?''',
                         (new_success, new_failure, new_avg_time, datetime.now(), self.bot_id, task_type))
            else:
                # إنشاء سجل جديد
                c.execute('''INSERT INTO learning_data (bot_id, task_type, success_count, failure_count, avg_completion_time)
                            VALUES (?, ?, ?, ?, ?)''',
                         (self.bot_id, task_type, 1 if success else 0, 0 if success else 1, completion_time))
            
            # تحديث إحصائيات البوت
            c.execute('SELECT total_tasks_completed, avg_efficiency FROM employees WHERE id = ?', 
                     (self.bot_id,))
            bot_stats = c.fetchone()
            
            new_total = bot_stats['total_tasks_completed'] + 1
            new_efficiency = ((bot_stats['avg_efficiency'] * bot_stats['total_tasks_completed']) + 
                            (100 if success else 50)) / new_total
            
            c.execute('''UPDATE employees 
                        SET total_tasks_completed = ?, avg_efficiency = ?, last_active = ?
                        WHERE id = ?''',
                     (new_total, new_efficiency, datetime.now(), self.bot_id))
            
            conn.commit()
            conn.close()
            
            # تسجيل في الذاكرة
            self.task_history.append({
                'task_id': task_id,
                'task_type': task_type,
                'completion_time': completion_time,
                'success': success,
                'timestamp': datetime.now()
            })
            
            logger.info(f"تم إكمال المهمة {task_id} بواسطة البوت {self.bot_id}")
            
            return True
            
        except Exception as e:
            logger.error(f"خطأ في إكمال المهمة: {str(e)}")
            return False
    
    def classify_task(self, task_description: str) -> str:
        """تصنيف المهمة"""
        task_assigner = SmartTaskAssigner()
        return task_assigner.classify_task(task_description)
    
    def get_experience_level(self, task_type: str) -> float:
        """الحصول على مستوى الخبرة في نوع المهمة"""
        try:
            conn = get_db()
            c = conn.cursor()
            c.execute('SELECT success_count, failure_count FROM learning_data WHERE bot_id = ? AND task_type = ?',
                     (self.bot_id, task_type))
            data = c.fetchone()
            conn.close()
            
            if data:
                total = data['success_count'] + data['failure_count']
                if total > 0:
                    return data['success_count'] / total * 100
            return 0.0
            
        except Exception as e:
            logger.error(f"خطأ في حساب مستوى الخبرة: {str(e)}")
            return 0.0

# ===========================================
# نظام الذكاء الاصطناعي
# ===========================================

class AI_Manager:
    """مدير الذكاء الاصطناعي للشركة"""
    
    def __init__(self):
        self.api_key = os.getenv('OPENAI_API_KEY')
        if self.api_key:
            openai.api_key = self.api_key
            logger.info("تم تهيئة AI_Manager بنجاح")
        else:
            logger.warning("لم يتم تعيين مفتاح OpenAI API")
    
    def analyze_company_performance(self, period_days: int = 7) -> Dict:
        """تحليل أداء الشركة باستخدام الذكاء الاصطناعي"""
        try:
            if not self.api_key:
                return self.generate_fallback_analysis(period_days)
            
            # جمع بيانات الأداء
            conn = get_db()
            c = conn.cursor()
            
            # استعلامات متقدمة
            queries = {
                'department_stats': '''
                    SELECT dept, 
                           COUNT(*) as total_tasks,
                           SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END) as completed_tasks,
                           AVG(CASE WHEN completed_at IS NOT NULL THEN 
                               (julianday(completed_at) - julianday(started_at)) * 24 * 60 
                               ELSE NULL END) as avg_completion_time_minutes,
                           AVG(efficiency_score) as avg_efficiency
                    FROM tasks
                    LEFT JOIN performance ON tasks.id = performance.task_id
                    WHERE tasks.created_at >= datetime('now', ?)
                    GROUP BY dept
                ''',
                
                'bot_performance': '''
                    SELECT employees.name, employees.dept,
                           employees.total_tasks_completed,
                           employees.avg_efficiency,
                           COUNT(DISTINCT tasks.id) as 
