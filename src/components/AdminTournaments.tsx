import { type FormEvent, useState } from 'react';
import { ImageIcon, Pencil, Plus, Search, Save, Trash2, Trophy, UploadCloud, X } from 'lucide-react';

type TournamentStatus = 'UPCOMING' | 'LIVE' | 'COMPLETED' | 'CANCELLED';
type Tournament = { id: string; title: string; prize_pool: number; entry_fee: number; max_players: number; participant_count: number; start_date: string; end_date?: string; start_at?: string; end_at?: string; rules: string; description?: string; image_url?: string; platform?: string; status?: TournamentStatus; featured?: boolean };
type TournamentDraft = { id?: string; title: string; prize_pool: number; entry_fee: number; max_players: number; start_date: string; end_date: string; start_at: string; end_at: string; rules: string; description: string; image_url: string; platform: string; status: TournamentStatus; featured: boolean };
type Props = { tournaments: Tournament[]; saveTournament: (draft: TournamentDraft, imageFile?: File) => Promise<boolean>; deleteTournament: (id: string) => Promise<boolean> };

const money = (amount: number) => `$${amount.toFixed(2)}`;
const statusLabel: Record<string, string> = { UPCOMING: 'قادمة', LIVE: 'مباشرة', COMPLETED: 'مكتملة', CANCELLED: 'ملغاة' };
const emptyDraft = (): TournamentDraft => ({ title: '', prize_pool: 500, entry_fee: 20, max_players: 16, start_date: '', end_date: '', start_at: '', end_at: '', rules: 'إقصاء مباشر • eFootball Mobile • 10 دقائق', description: '', image_url: '', platform: 'الهاتف', status: 'UPCOMING', featured: false });
const dateInput = (value?: string) => {
  if (!value) return '';
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? value : new Date(parsed.getTime() - parsed.getTimezoneOffset() * 60000).toISOString().slice(0, 16);
};
const dateOutput = (value: string) => value ? new Date(value).toISOString() : '';
const dateLabel = (value?: string) => value ? new Intl.DateTimeFormat('ar-MA', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(value)) : 'لاحقاً';
const toDraft = (item?: Tournament): TournamentDraft => ({ id: item?.id, title: item?.title || '', prize_pool: item?.prize_pool || 500, entry_fee: item?.entry_fee || 20, max_players: item?.max_players || 16, start_date: item?.start_date || '', end_date: item?.end_date || '', start_at: dateInput(item?.start_at), end_at: dateInput(item?.end_at), rules: item?.rules || '', description: item?.description || '', image_url: item?.image_url || '', platform: item?.platform || 'الهاتف', status: item?.status || 'UPCOMING', featured: Boolean(item?.featured) });
const Status = ({ value }: { value: string }) => <span className={`status-badge status-${value === 'COMPLETED' ? 'success' : value === 'CANCELLED' ? 'danger' : value === 'LIVE' ? 'warning' : 'info'}`}>{statusLabel[value] || value}</span>;
const Field = ({ label, value, onChange, type = 'text', placeholder }: { label: string; value: string; onChange: (value: string) => void; type?: string; placeholder?: string }) => <label className="form-field"><span>{label}</span><input type={type} value={value} placeholder={placeholder} onChange={event => onChange(event.target.value)} /></label>;

export function AdminTournamentsPage({ tournaments, saveTournament, deleteTournament }: Props) {
  const [query, setQuery] = useState('');
  const [editorOpen, setEditorOpen] = useState(false);
  const [editing, setEditing] = useState<Tournament>();
  const rows = tournaments.filter(item => !query || `${item.title} ${item.platform || ''} ${item.rules}`.toLowerCase().includes(query.toLowerCase()));
  const openEditor = (item?: Tournament) => { setEditing(item); setEditorOpen(true); };
  const remove = async (item: Tournament) => { if (window.confirm(`حذف البطولة «${item.title}»؟`)) await deleteTournament(item.id); };
  return <div className="admin-page">
    <div className="admin-tournaments-hero"><div className="section-admin-header"><div className="page-title"><span className="page-icon tone-amber"><Trophy className="h-6 w-6" /></span><span><h2>إدارة البطولات</h2><p>أنشئ بطولات عصرية وعدّل تفاصيلها ومواعيدها الفعلية.</p></span></div></div><button className="primary-button" onClick={() => openEditor()}><Plus className="h-4 w-4" />إضافة بطولة</button></div>
    <div className="admin-filters"><div className="search-box"><Search className="h-4 w-4" /><input value={query} onChange={event => setQuery(event.target.value)} placeholder="ابحث في البطولات" /></div><span className="records-count">{rows.length} بطولة</span></div>
    {rows.length ? <div className="admin-tournament-grid">{rows.map(item => <article className="admin-tournament-card" key={item.id}><div className="admin-tournament-media">{item.image_url ? <img src={item.image_url} alt={item.title} /> : <ImageIcon className="h-10 w-10" />}<div><Status value={item.status || 'UPCOMING'} />{item.featured && <span className="featured-label">مميزة</span>}</div></div><div className="admin-tournament-body"><div className="split-row"><div><h3>{item.title}</h3><p>{item.description || item.rules}</p></div><span className="capacity">{item.participant_count}/{item.max_players}</span></div><div className="admin-tournament-facts"><span><small>الجائزة</small><b className="amber-text">{money(item.prize_pool)}</b></span><span><small>الدخول</small><b>{money(item.entry_fee)}</b></span><span><small>المنصة</small><b>{item.platform || 'الهاتف'}</b></span><span><small>البداية</small><b>{dateLabel(item.start_at) !== 'لاحقاً' ? dateLabel(item.start_at) : item.start_date || 'لاحقاً'}</b></span></div><div className="admin-tournament-actions"><button className="secondary-button small" onClick={() => openEditor(item)}><Pencil className="h-3.5 w-3.5" />تعديل</button><button className="danger-button small" onClick={() => void remove(item)}><Trash2 className="h-3.5 w-3.5" />حذف</button></div></div></article>)}</div> : <div className="empty-state"><Trophy className="h-8 w-8" /><p>لا توجد بطولات مطابقة للبحث.</p></div>}
    {editorOpen && <TournamentEditor tournament={editing} saveTournament={saveTournament} onClose={() => { setEditorOpen(false); setEditing(undefined); }} />}
  </div>;
}

function TournamentEditor({ tournament, saveTournament, onClose }: { tournament?: Tournament; saveTournament: Props['saveTournament']; onClose: () => void }) {
  const [draft, setDraft] = useState<TournamentDraft>(() => toDraft(tournament));
  const [imageFile, setImageFile] = useState<File>();
  const [error, setError] = useState('');
  const update = (key: keyof TournamentDraft, value: string | number | boolean) => setDraft(old => ({ ...old, [key]: value }));
  const submit = async (event: FormEvent) => {
    event.preventDefault();
    if (!draft.title.trim()) return setError('اكتب اسم البطولة.');
    if (draft.max_players < 2) return setError('عدد اللاعبين يجب أن يكون 2 على الأقل.');
    if (draft.prize_pool < 0 || draft.entry_fee < 0) return setError('القيم المالية لا يمكن أن تكون سالبة.');
    if (draft.start_at && draft.end_at && new Date(draft.end_at) <= new Date(draft.start_at)) return setError('موعد النهاية يجب أن يكون بعد البداية.');
    const okay = await saveTournament({ ...draft, title: draft.title.trim(), start_at: dateOutput(draft.start_at), end_at: dateOutput(draft.end_at), rules: draft.rules.trim(), description: draft.description.trim() }, imageFile);
    if (!okay) return setError('تعذر حفظ البطولة. تحقق من إعداد Storage في Supabase ثم حاول مرة أخرى.');
    onClose();
  };
  return <div className="modal-backdrop"><div className="modal-card max-w-2xl"><button className="modal-close" onClick={onClose} aria-label="إغلاق"><X className="h-5 w-5" /></button><div className="modal-heading"><span className="panel-icon amber"><Trophy className="h-5 w-5" /></span><span><h2>{tournament ? 'تعديل البطولة' : 'إضافة بطولة جديدة'}</h2><p>المواعيد هنا تحفظ كتوقيت فعلي وتظهر في البث والتنبيهات.</p></span></div><form className="modal-body form-stack" onSubmit={submit}>{error && <div className="notice notice-error">{error}</div>}<div className="form-grid"><Field label="اسم البطولة" value={draft.title} onChange={value => update('title', value)} /><Field label="المنصة" value={draft.platform} onChange={value => update('platform', value)} /></div><div className="form-grid"><Field label="قيمة الجوائز ($)" type="number" value={String(draft.prize_pool)} onChange={value => update('prize_pool', Number(value))} /><Field label="رسوم التسجيل ($)" type="number" value={String(draft.entry_fee)} onChange={value => update('entry_fee', Number(value))} /><Field label="الحد الأقصى للاعبين" type="number" value={String(draft.max_players)} onChange={value => update('max_players', Number(value))} /></div><div className="form-grid"><Field label="موعد البداية الفعلي" type="datetime-local" value={draft.start_at} onChange={value => update('start_at', value)} /><Field label="موعد النهاية الفعلي" type="datetime-local" value={draft.end_at} onChange={value => update('end_at', value)} /></div><div className="form-grid"><Field label="وصف الموعد الظاهر" value={draft.start_date} onChange={value => update('start_date', value)} placeholder="مثال: الجمعة، 21:00" /><Field label="موعد النهاية الظاهر" value={draft.end_date} onChange={value => update('end_date', value)} placeholder="اختياري" /></div><div className="form-grid"><label className="form-field"><span>حالة البطولة</span><select value={draft.status} onChange={event => update('status', event.target.value as TournamentStatus)}><option value="UPCOMING">قادمة</option><option value="LIVE">مباشرة</option><option value="COMPLETED">مكتملة</option><option value="CANCELLED">ملغاة</option></select></label><label className="form-field"><span>صورة الغلاف من الجهاز</span><span className="file-input"><UploadCloud className="h-4 w-4" />{imageFile ? imageFile.name : 'اختر صورة'}<input type="file" accept="image/*" onChange={event => setImageFile(event.target.files?.[0])} /></span></label></div><label className="form-field"><span>القواعد</span><textarea value={draft.rules} onChange={event => update('rules', event.target.value)} rows={3} /></label><label className="form-field"><span>الوصف</span><textarea value={draft.description} onChange={event => update('description', event.target.value)} rows={3} /></label><label className="check-field"><input type="checkbox" checked={draft.featured} onChange={event => update('featured', event.target.checked)} /><span>إظهار كبطولة مميزة</span></label><button className="primary-button full" type="submit"><Save className="h-4 w-4" />حفظ البطولة</button></form></div></div>;
}
