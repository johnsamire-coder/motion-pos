// js/config.js - الإعدادات المركزية
const SUPABASE_URL = 'https://qyrezfpzcuioxasxjhiq.supabase.co';
const SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InF5cmV6ZnB6Y3Vpb3hhc3hqaGlxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTExNzY2ODAsImV4cCI6MjEwNjc1MjY4MH0._BrruPh4V6IUKa78u5CDJl-I4cRmU0RvZf5MsmAUXTQ';
const _supabase = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

let currentUser = null;
let currentBranch = null;
let taxSettings = { 
    vat_percentage: 14.00, 
    service_charge_percentage: 12.00,
    enable_vat: true,  // الضريبة اختيارية
    enable_service: true // الخدمة اختيارية
};

function formatCurrency(amount) {
    return (parseFloat(amount) || 0).toFixed(2) + ' ج.م';
}

function showToast(message, type = 'success') {
    alert((type === 'error' ? '❌ ' : '✅ ') + message);
}
