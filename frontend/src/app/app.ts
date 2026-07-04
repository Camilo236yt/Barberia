import { CommonModule } from '@angular/common';
import { ChangeDetectorRef, Component, OnDestroy, OnInit } from '@angular/core';
import { FormsModule } from '@angular/forms';

type PaymentMethod = 'cash' | 'nequi';
type SaleStatus = 'confirmed' | 'pending_review' | 'rejected' | 'annulled' | 'sync_pending';
type SaleKind = 'service' | 'product';
type ClosureStatus = 'closed' | 'reopened';
type ViewName = 'dashboard' | 'sales' | 'accounting' | 'history' | 'information';

interface Branch {
  id: string;
  name: string;
  active: boolean;
}

interface Barber {
  id: string;
  name: string;
  active: boolean;
  branch_id: string;
  commission_rate?: number;
}

interface ServiceItem {
  id: string;
  name: string;
  price: number;
  branch_id: string;
}

interface Sale {
  id: string;
  created_at: string;
  branch_id: string;
  branch_name: string;
  sale_kind?: SaleKind;
  barber_id: string | null;
  barber_name: string;
  service_id: string;
  service_name: string;
  amount: number;
  base_amount?: number;
  listed_price?: number | null;
  tip_amount?: number;
  payment_method: PaymentMethod;
  proof_url?: string | null;
  proof_note: string;
  client_name: string;
  status: SaleStatus;
  reviewed_at?: string;
  client_request_id?: string;
}

interface PendingOfflineSale {
  id: string;
  branch_id: string;
  queued_at: string;
  payload: Record<string, unknown>;
  last_error?: string;
}

class ApiRequestError extends Error {
  constructor(
    message: string,
    readonly status = 0,
    readonly reconnectable = false,
  ) {
    super(message);
    this.name = 'ApiRequestError';
  }
}

interface Expense {
  id: string;
  date: string;
  created_at: string;
  branch_id: string;
  description: string;
  amount: number;
  expense_type?: 'shop' | 'barber';
  barber_id?: string | null;
  barber_name?: string | null;
}

interface ClosureBarber {
  barber_id: string;
  barber_name: string;
  sales_count: number;
  total: number;
  base_total?: number;
  tip_total?: number;
  nequi_total?: number;
  cash_payment_total?: number;
  cash_base_total?: number;
  cash_shop_share?: number;
  nequi_base_total?: number;
  nequi_shop_share?: number;
  commission: number;
  commission_rate?: number;
  shop_share?: number;
}

interface ClosureEvent {
  type: 'closed' | 'reopened';
  at: string;
  counted_cash?: number;
  expected_cash?: number;
  cash_difference?: number;
  total_confirmed?: number;
  cash_total?: number;
  nequi_confirmed?: number;
  sales_count?: number;
}

interface Closure {
  id: string;
  date: string;
  branch_id: string;
  branch_name: string;
  closed_at: string;
  status: ClosureStatus;
  counted_cash: number;
  expected_cash: number;
  cash_difference: number;
  total_confirmed: number;
  cash_total: number;
  nequi_confirmed: number;
  nequi_pending: number;
  sales_count: number;
  pending_nequi_count: number;
  commission_rate: number;
  barbers: ClosureBarber[];
  events?: ClosureEvent[];
  reopened_at?: string;
}

interface BootstrapResponse {
  branches: Branch[];
  barbers: Barber[];
  services: ServiceItem[];
  sales?: Sale[];
  closures?: Closure[];
  expenses?: Expense[];
  settings: {
    commission_rate: number;
    currency: string;
    business_whatsapp_country_code: string;
  };
  capabilities?: {
    historical_sales?: boolean;
    strict_date_filtering?: boolean;
  };
}

interface AdminOptionsResponse {
  role: 'local' | 'online';
  selected_branch_id: string | null;
  occupied_branch_id: string | null;
  connected_devices?: number;
  max_devices?: number;
  branches: Branch[];
}

interface HistoryBackupStatus {
  state?: 'idle' | 'queued' | 'uploading' | 'success' | 'error';
  date?: string;
  month?: string;
  message?: string;
  at?: string;
}

interface HistoryBackupResponse {
  local_months: string[];
  remote_months: string[];
  status?: HistoryBackupStatus;
  remote_error?: string;
}

interface ChartPoint {
  key: string;
  label: string;
  value: number;
  percent: number;
}

interface CalendarDay {
  key: string;
  day: number;
  inMonth: boolean;
  hasSales: boolean;
  isFuture: boolean;
}

@Component({
  selector: 'app-root',
  imports: [CommonModule, FormsModule],
  templateUrl: './app.html',
  styleUrl: './app.css',
})
export class App implements OnInit, OnDestroy {
  branches: Branch[] = [];
  barbers: Barber[] = [];
  services: ServiceItem[] = [];
  sales: Sale[] = [];
  closures: Closure[] = [];
  expenses: Expense[] = [];
  settings = {
    commission_rate: 0.5,
    currency: 'COP',
    business_whatsapp_country_code: '57',
  };

  selectedView: ViewName = 'dashboard';
  isOnline = false;
  realtimeConnected = false;
  dataLoading = false;
  networkBusy = false;
  lastSyncAt = '';
  pendingOfflineSales: PendingOfflineSale[] = [];
  syncingOfflineSales = false;
  offlineSyncMessage = '';
  offlineSyncMessageType: 'success' | 'error' | '' = '';
  saleSaving = false;
  adminRole: 'local' | 'online' = 'local';
  adminToken = '';
  activeBranchId = '';
  availableBranches: Branch[] = [];
  branchPickerOpen = true;
  accessLoading = true;
  accessError = '';
  connectedAdminDevices = 0;
  maxAdminDevices = 10;

  selectedServiceId = '';
  saleKind: SaleKind = 'service';
  fridgeProductName = 'Agua';
  isSpecialService = false;
  specialServiceName = '';
  selectedPayment: PaymentMethod = 'cash';
  proofDataUrl = '';
  proofPreviewUrl = '';
  proofProcessing = false;
  countedCash = 0;
  examinedDate = '';
  examinedBranchId = '';
  accountingDate = this.todayKey();
  accountingMonthKey = this.todayKey().slice(0, 7);
  accountingBarberFilterId = 'all';
  accountingSaleFormOpen = false;
  supportsHistoricalSales = false;
  accountingSaleSaving = false;
  accountingSaleMessage = '';
  accountingSaleMessageType: 'success' | 'error' | '' = '';
  accountingProofDataUrl = '';
  accountingProofPreviewUrl = '';
  accountingSaleKind: SaleKind = 'service';
  accountingFridgeProductName = 'Agua';
  accountingCustomServiceName = '';
  accountingSaleForm = {
    barber_id: '',
    service_id: '',
    amount: 0,
    payment_method: 'cash' as PaymentMethod,
    client_name: '',
    proof_note: '',
    sale_time: '',
  };
  expenseSaving = false;
  expenseMessage = '';
  expenseMessageType: 'success' | 'error' | '' = '';
  newExpense = {
    description: '',
    amount: 0,
    expense_type: 'shop' as 'shop' | 'barber',
    barber_id: '',
  };
  historyMonthKey = this.todayKey().slice(0, 7);
  localHistoryMonths: string[] = [];
  remoteHistoryMonths: string[] = [];
  historyBackupLoading = false;
  historyUploadLoading = false;
  historyBackupMessage = '';
  historyBackupMessageType: 'success' | 'error' | '' = '';
  historyActionMessage = '';
  historyActionMessageType: 'success' | 'error' | '' = '';
  editingSale: Sale | null = null;
  saleEditContext: 'history' | 'accounting' = 'history';
  historySaleSaving = false;
  accountingMovementMessage = '';
  accountingMovementMessageType: 'success' | 'error' | '' = '';
  editSaleForm = {
    barber_id: '',
    service_name: '',
    amount: 0,
    payment_method: 'cash' as PaymentMethod,
    client_name: '',
    proof_note: '',
  };
  backupProgressVisible = false;
  backupProgress = 0;
  backupProgressState: 'queued' | 'uploading' | 'success' | 'error' = 'queued';
  backupProgressMessage = '';
  backupTargetDate = '';
  backupProgressContext: 'close' | 'reopen' | 'manual' = 'close';

  saleForm = {
    barber_id: '',
    amount: 0,
    client_name: '',
    proof_note: '',
  };

  newBarberName = '';
  newService = {
    name: '',
    price: 0,
  };

  saleMessage = '';
  saleMessageType: 'success' | 'error' | '' = '';
  shiftActionMessage = '';
  shiftActionMessageType: 'success' | 'error' | '' = '';
  editingShiftSaleId = '';
  editingShiftAmount = 0;
  shiftSaleSaving = false;
  closeMessage = '';
  closeMessageType: 'success' | 'error' | '' = '';
  infoMessage = '';
  infoMessageType: 'success' | 'error' | '' = '';
  private refreshTimer?: number;
  private realtimeRefreshTimer?: number;
  private dataLoadPromise?: Promise<void>;
  private loadingBranchId = '';
  private pendingRequests = 0;
  private backupStatusTimer?: number;
  private backupStatusBusy = false;
  private localSessionTimer?: number;
  private offlineSyncTimer?: number;
  private localSessionId = '';
  private adminDeviceId = '';
  private eventSource?: EventSource;
  private messageTimers: number[] = [];
  private destroyed = false;
  private readonly localPageHideHandler = () => this.closeLocalSession();
  private readonly localPageShowHandler = () => this.startLocalSession();

  constructor(private readonly changeDetector: ChangeDetectorRef) {}

  ngOnInit(): void {
    this.detectPortalMode();
    this.adminDeviceId = this.getAdminDeviceId();
    this.loadOfflineSales();
    this.startLocalSession();
    this.loadAdminOptions();
    this.connectRealtime();
    this.refreshTimer = window.setInterval(() => {
      if (this.realtimeConnected) return;
      if (this.activeBranchId) this.loadData(true);
      else this.loadAdminOptions(true);
    }, 60000);
    this.offlineSyncTimer = window.setInterval(() => {
      if (this.pendingOfflineSales.length) {
        void this.flushOfflineSales();
      } else if (!this.realtimeConnected && this.activeBranchId) {
        void this.loadData(true);
      }
    }, 5000);
  }

  ngOnDestroy(): void {
    this.destroyed = true;
    if (this.refreshTimer) window.clearInterval(this.refreshTimer);
    if (this.realtimeRefreshTimer) window.clearTimeout(this.realtimeRefreshTimer);
    if (this.backupStatusTimer) window.clearInterval(this.backupStatusTimer);
    if (this.offlineSyncTimer) window.clearInterval(this.offlineSyncTimer);
    this.closeLocalSession();
    window.removeEventListener('pagehide', this.localPageHideHandler);
    window.removeEventListener('pageshow', this.localPageShowHandler);
    this.eventSource?.close();
    this.messageTimers.forEach((timer) => window.clearTimeout(timer));
  }

  detectPortalMode(): void {
    const path = window.location.pathname.toLowerCase();
    const params = new URLSearchParams(window.location.search);
    this.adminRole = path.startsWith('/admin/online') ? 'online' : 'local';
    this.adminToken = this.adminRole === 'online' ? params.get('token') || '' : '';
    this.selectedView = 'dashboard';
  }

  private startLocalSession(): void {
    const hostname = window.location.hostname.toLowerCase();
    const isLocalHost = ['localhost', '127.0.0.1', '::1'].includes(hostname);
    if (this.adminRole !== 'local' || !isLocalHost || this.localSessionTimer) return;

    this.localSessionId =
      window.crypto?.randomUUID?.() ||
      `${Date.now()}-${Math.random().toString(36).slice(2)}-${Math.random().toString(36).slice(2)}`;

    const heartbeat = () => {
      if (!this.localSessionId) return;
      void fetch('/api/local-ui/heartbeat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ session_id: this.localSessionId }),
        keepalive: true,
      }).catch(() => undefined);
    };

    heartbeat();
    this.localSessionTimer = window.setInterval(heartbeat, 3000);
    window.addEventListener('pagehide', this.localPageHideHandler);
    window.addEventListener('pageshow', this.localPageShowHandler);
  }

  private closeLocalSession(): void {
    if (this.localSessionTimer) {
      window.clearInterval(this.localSessionTimer);
      this.localSessionTimer = undefined;
    }
    if (!this.localSessionId) return;

    const payload = JSON.stringify({ session_id: this.localSessionId });
    this.localSessionId = '';
    try {
      navigator.sendBeacon(
        '/api/local-ui/close',
        new Blob([payload], { type: 'application/json' }),
      );
    } catch {
      void fetch('/api/local-ui/close', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: payload,
        keepalive: true,
      }).catch(() => undefined);
    }
  }

  async loadAdminOptions(silent = false, keepPickerOpen = false): Promise<void> {
    try {
      const options = await this.api<AdminOptionsResponse>('/api/admin/options');
      this.adminRole = options.role;
      this.availableBranches = options.branches || [];
      this.connectedAdminDevices = options.connected_devices || 1;
      this.maxAdminDevices = options.max_devices || 10;
      this.accessError = '';
      if (options.selected_branch_id && !keepPickerOpen) {
        this.activeBranchId = options.selected_branch_id;
        this.branchPickerOpen = false;
        await this.loadData(true);
      }
    } catch (error) {
      if (!silent) this.accessError = this.errorMessage(error);
    } finally {
      this.accessLoading = false;
      this.renderNow();
    }
  }

  async selectBranch(branchId: string): Promise<void> {
    this.accessLoading = true;
    this.renderNow();
    try {
      const result = await this.api<{ branch: Branch }>('/api/admin/select-branch', {
        method: 'POST',
        body: JSON.stringify({ branch_id: branchId }),
      });
      this.activeBranchId = result.branch.id;
      this.branchPickerOpen = false;
      this.examinedDate = '';
      this.examinedBranchId = branchId;
      this.countedCash = 0;
      await this.loadData(true);
    } catch (error) {
      this.accessError = this.errorMessage(error);
      await this.loadAdminOptions(true);
    } finally {
      this.accessLoading = false;
      this.renderNow();
    }
  }

  async openBranchPicker(): Promise<void> {
    this.branchPickerOpen = true;
    this.accessLoading = true;
    await this.loadAdminOptions(true, true);
  }

  async loadData(silent = false): Promise<void> {
    if (!this.activeBranchId) return;
    const requestedBranchId = this.activeBranchId;
    if (this.dataLoadPromise) {
      if (this.loadingBranchId === requestedBranchId) return this.dataLoadPromise;
      await this.dataLoadPromise;
      if (this.activeBranchId !== requestedBranchId) return;
    }

    this.loadingBranchId = requestedBranchId;
    this.dataLoading = true;
    this.renderNow();
    this.dataLoadPromise = this.performDataLoad(silent, requestedBranchId);
    try {
      await this.dataLoadPromise;
    } finally {
      this.dataLoadPromise = undefined;
      this.loadingBranchId = '';
      this.dataLoading = false;
      this.renderNow();
    }
  }

  private async performDataLoad(silent: boolean, requestedBranchId: string): Promise<void> {
    try {
      const data = await this.api<BootstrapResponse>('/api/bootstrap');
      if (this.activeBranchId !== requestedBranchId) return;
      this.branches = (data.branches || []).filter((branch) => branch.active !== false);
      this.barbers = data.barbers || [];
      this.services = data.services || [];
      this.sales = data.sales || [];
      this.closures = data.closures || [];
      this.expenses = data.expenses || [];
      this.settings = data.settings || this.settings;
      this.applyOfflineSalesToView();
      this.supportsHistoricalSales =
        data.capabilities?.historical_sales === true &&
        data.capabilities?.strict_date_filtering === true;
      this.ensureDefaults();
      const currentClosure = this.currentClosure();
      if (currentClosure?.status === 'closed') this.countedCash = currentClosure.counted_cash;
      if (!this.examinedDate) {
        const latestClosure = this.orderedClosures()[0];
        this.examinedDate = latestClosure?.date || '';
        this.examinedBranchId = this.activeBranchId;
        if (latestClosure?.date) this.historyMonthKey = latestClosure.date.slice(0, 7);
      }
      this.isOnline = true;
      this.lastSyncAt = new Intl.DateTimeFormat('es-CO', {
        hour: '2-digit',
        minute: '2-digit',
        second: '2-digit',
      }).format(new Date());
      if (this.pendingOfflineSales.length) void this.flushOfflineSales();
    } catch (error) {
      this.isOnline = false;
      if (!silent) this.showSaleMessage(this.errorMessage(error), 'error');
    }
  }

  ensureDefaults(): void {
    if (!this.barbers.some((barber) => barber.id === this.saleForm.barber_id)) {
      this.saleForm.barber_id = this.barbers[0]?.id || '';
    }
    if (
      this.saleKind === 'service' &&
      !this.isSpecialService &&
      !this.services.some((service) => service.id === this.selectedServiceId)
    ) {
      this.selectedServiceId = '';
      if (this.services.length) this.selectService(this.services[0]);
    }
    if (!this.barbers.some((barber) => barber.id === this.accountingSaleForm.barber_id)) {
      this.accountingSaleForm.barber_id = this.barbers[0]?.id || '';
    }
    if (
      this.accountingBarberFilterId !== 'all' &&
      !this.barbers.some((barber) => barber.id === this.accountingBarberFilterId)
    ) {
      this.accountingBarberFilterId = 'all';
    }
    if (
      this.accountingSaleKind === 'service' &&
      this.accountingSaleForm.service_id !== 'especial' &&
      !this.services.some((service) => service.id === this.accountingSaleForm.service_id)
    ) {
      const firstService = this.services[0];
      this.accountingSaleForm.service_id = firstService?.id || '';
      this.accountingSaleForm.amount = firstService?.price || 0;
    }
  }

  setView(view: ViewName): void {
    this.selectedView = view;
  }

  activeBranch(): Branch | undefined {
    return this.branches.find((branch) => branch.id === this.activeBranchId);
  }

  branchName(branchId: string): string {
    return this.branches.find((branch) => branch.id === branchId)?.name || 'Barbería';
  }

  selectService(service: ServiceItem): void {
    this.saleKind = 'service';
    this.isSpecialService = false;
    this.specialServiceName = '';
    this.selectedServiceId = service.id;
    this.saleForm.amount = service.price;
  }

  selectBarber(barberId: string): void {
    this.saleForm.barber_id = barberId;
  }

  selectSpecialService(): void {
    this.saleKind = 'service';
    this.isSpecialService = true;
    this.selectedServiceId = '';
    this.specialServiceName = '';
    this.saleForm.amount = 0;
  }

  selectedServicePrice(): number {
    return this.services.find((service) => service.id === this.selectedServiceId)?.price || 0;
  }

  newSaleTip(): number {
    if (this.saleKind === 'product' || this.isSpecialService || !this.selectedServiceId) return 0;
    return Math.max(0, Number(this.saleForm.amount || 0) - this.selectedServicePrice());
  }

  selectSaleKind(kind: SaleKind): void {
    this.saleKind = kind;
    this.saleMessage = '';
    if (kind === 'product') {
      this.isSpecialService = false;
      this.selectedServiceId = '';
      if (!this.fridgeProductName.trim()) this.fridgeProductName = 'Agua';
      this.saleForm.amount = 0;
      return;
    }
    if (this.services.length) this.selectService(this.services[0]);
  }

  selectFridgeProduct(name: string): void {
    this.saleKind = 'product';
    this.fridgeProductName = name;
  }

  isProductSale(sale: Sale): boolean {
    return sale.sale_kind === 'product' || !sale.barber_id;
  }

  saleResponsibleLabel(sale: Sale): string {
    return this.isProductSale(sale) ? 'Barbería · Nevera' : sale.barber_name;
  }

  accountingSaleTip(): number {
    if (
      this.accountingSaleKind === 'product' ||
      this.accountingSpecialService() ||
      !this.accountingSaleForm.service_id
    ) return 0;
    const price =
      this.services.find((service) => service.id === this.accountingSaleForm.service_id)?.price || 0;
    return Math.max(0, Number(this.accountingSaleForm.amount || 0) - price);
  }

  saleTip(sale: Sale): number {
    const tip = Number(sale.tip_amount || 0);
    return tip > 0 && tip <= Number(sale.amount || 0) ? tip : 0;
  }

  saleBase(sale: Sale): number {
    return Number(sale.amount || 0) - this.saleTip(sale);
  }

  setPayment(method: PaymentMethod): void {
    this.selectedPayment = method;
  }

  async createBarber(): Promise<void> {
    try {
      await this.api('/api/barbers', {
        method: 'POST',
        body: JSON.stringify({ name: this.newBarberName }),
      });
      this.newBarberName = '';
      this.showInfoMessage('Barbero creado correctamente.', 'success');
      await this.loadData(true);
    } catch (error) {
      this.showInfoMessage(this.errorMessage(error), 'error');
    }
  }

  async updateBarber(barber: Barber): Promise<void> {
    try {
      await this.api(`/api/barbers/${barber.id}`, {
        method: 'POST',
        body: JSON.stringify({ name: barber.name }),
      });
      this.showInfoMessage('Nombre del barbero actualizado.', 'success');
      await this.loadData(true);
    } catch (error) {
      this.showInfoMessage(this.errorMessage(error), 'error');
      await this.loadData(true);
    }
  }

  async deleteBarber(barber: Barber): Promise<void> {
    if (!window.confirm(`¿Eliminar a ${barber.name}? Las ventas históricas no se borrarán.`)) return;
    try {
      await this.api(`/api/barbers/${barber.id}/delete`, {
        method: 'POST',
        body: JSON.stringify({}),
      });
      this.showInfoMessage('Barbero eliminado. El historial fue conservado.', 'success');
      await this.loadData(true);
    } catch (error) {
      this.showInfoMessage(this.errorMessage(error), 'error');
    }
  }

  async createService(): Promise<void> {
    try {
      await this.api('/api/services', {
        method: 'POST',
        body: JSON.stringify(this.newService),
      });
      this.newService = { name: '', price: 0 };
      this.showInfoMessage('Servicio y precio creados correctamente.', 'success');
      await this.loadData(true);
    } catch (error) {
      this.showInfoMessage(this.errorMessage(error), 'error');
    }
  }

  async updateService(service: ServiceItem): Promise<void> {
    try {
      await this.api(`/api/services/${service.id}`, {
        method: 'POST',
        body: JSON.stringify({ name: service.name, price: Number(service.price) }),
      });
      this.showInfoMessage('Servicio actualizado.', 'success');
      await this.loadData(true);
    } catch (error) {
      this.showInfoMessage(this.errorMessage(error), 'error');
      await this.loadData(true);
    }
  }

  async deleteService(service: ServiceItem): Promise<void> {
    if (!window.confirm(`¿Eliminar ${service.name}? Las ventas históricas no se borrarán.`)) return;
    try {
      await this.api(`/api/services/${service.id}/delete`, {
        method: 'POST',
        body: JSON.stringify({}),
      });
      this.showInfoMessage('Servicio eliminado. El historial fue conservado.', 'success');
      await this.loadData(true);
    } catch (error) {
      this.showInfoMessage(this.errorMessage(error), 'error');
    }
  }

  async submitSale(): Promise<void> {
    if (this.saleSaving) return;
    if (!this.activeBranchId) {
      this.showSaleMessage('Selecciona primero una barbería.', 'error');
      return;
    }
    if (this.isCurrentDayClosed()) {
      this.showSaleMessage('La caja de esta barbería está cerrada.', 'error');
      return;
    }
    if (this.saleKind === 'service' && !this.isSpecialService && !this.selectedServiceId) {
      this.showSaleMessage('Selecciona un servicio.', 'error');
      return;
    }
    if (
      this.saleKind === 'service' &&
      this.isSpecialService &&
      this.specialServiceName.trim().length < 2
    ) {
      this.showSaleMessage('Escribe el nombre del servicio especial.', 'error');
      return;
    }
    if (this.saleKind === 'product' && this.fridgeProductName.trim().length < 2) {
      this.showSaleMessage('Escribe el nombre del producto de la nevera.', 'error');
      return;
    }
    if (this.selectedPayment === 'nequi' && !this.proofDataUrl) {
      this.showSaleMessage('Sube o toma la foto del comprobante.', 'error');
      return;
    }
    if (Number(this.saleForm.amount) <= 0) {
      this.showSaleMessage('El valor cobrado debe ser mayor a cero.', 'error');
      return;
    }

    const now = new Date();
    const saleDate = this.localDateKey(now);
    const saleTime =
      `${String(now.getHours()).padStart(2, '0')}:${String(now.getMinutes()).padStart(2, '0')}`;
    const clientRequestId = this.newClientRequestId();
    const payload: Record<string, unknown> = {
      branch_id: this.activeBranchId,
      sale_kind: this.saleKind,
      barber_id: this.saleKind === 'product' ? null : this.saleForm.barber_id,
      service_id: this.saleKind === 'product' ? '' : this.selectedServiceId,
      custom_service_name:
        this.saleKind === 'product'
          ? this.fridgeProductName.trim()
          : this.isSpecialService
            ? this.specialServiceName.trim()
            : '',
      amount: Number(this.saleForm.amount),
      payment_method: this.selectedPayment,
      proof_image: this.proofDataUrl,
      proof_note: this.saleForm.proof_note,
      client_name: this.saleForm.client_name,
      sale_date: saleDate,
      sale_time: saleTime,
      client_request_id: clientRequestId,
    };
    this.saleSaving = true;
    const saleController = new AbortController();
    const saleTimeout = window.setTimeout(() => saleController.abort(), 8000);
    try {
      await this.api('/api/sales', {
        method: 'POST',
        body: JSON.stringify(payload),
        signal: saleController.signal,
      });
      this.resetSaleAfterSave();
      this.showSaleMessage(`Venta guardada en ${this.activeBranch()?.name}.`, 'success');
      await this.loadData(true);
    } catch (error) {
      if (this.isReconnectableError(error)) {
        const queued = this.enqueueOfflineSale({
          id: clientRequestId,
          branch_id: this.activeBranchId,
          queued_at: new Date().toISOString(),
          payload,
        });
        if (queued) {
          this.resetSaleAfterSave();
          this.showSaleMessage(
            `Venta guardada en este dispositivo. Se sincronizará automáticamente al reconectar (${this.pendingOfflineSales.length} pendiente${this.pendingOfflineSales.length === 1 ? '' : 's'}).`,
            'success',
          );
        } else {
          this.showSaleMessage(
            'No se pudo guardar la venta sin conexión. Libera espacio del navegador y vuelve a intentarlo.',
            'error',
          );
        }
      } else {
        this.showSaleMessage(this.errorMessage(error), 'error');
      }
    } finally {
      window.clearTimeout(saleTimeout);
      this.saleSaving = false;
      this.renderNow();
    }
  }

  pendingOfflineSaleCount(): number {
    return this.pendingOfflineSales.length;
  }

  private offlineSalesStorageKey(): string {
    return 'capitan-gold-offline-sales-v1';
  }

  private newClientRequestId(): string {
    const random =
      window.crypto?.randomUUID?.() ||
      `${Date.now()}-${Math.random().toString(36).slice(2)}`;
    return `venta-${this.adminDeviceId}-${random}`.slice(0, 160);
  }

  private loadOfflineSales(): void {
    try {
      const parsed = JSON.parse(
        window.localStorage.getItem(this.offlineSalesStorageKey()) || '[]',
      ) as PendingOfflineSale[];
      this.pendingOfflineSales = Array.isArray(parsed)
        ? parsed.filter(
            (item) =>
              item &&
              typeof item.id === 'string' &&
              typeof item.branch_id === 'string' &&
              item.payload &&
              typeof item.payload === 'object',
          )
        : [];
    } catch {
      this.pendingOfflineSales = [];
    }
  }

  private persistOfflineSales(): boolean {
    try {
      window.localStorage.setItem(
        this.offlineSalesStorageKey(),
        JSON.stringify(this.pendingOfflineSales),
      );
      return true;
    } catch {
      return false;
    }
  }

  private enqueueOfflineSale(item: PendingOfflineSale): boolean {
    if (this.pendingOfflineSales.some((pending) => pending.id === item.id)) return true;
    this.pendingOfflineSales.push(item);
    if (!this.persistOfflineSales()) {
      this.pendingOfflineSales = this.pendingOfflineSales.filter(
        (pending) => pending.id !== item.id,
      );
      return false;
    }
    this.applyOfflineSalesToView();
    this.offlineSyncMessage = 'Modo reconexión activo: las ventas están protegidas en este dispositivo.';
    this.offlineSyncMessageType = '';
    return true;
  }

  private applyOfflineSalesToView(): void {
    if (!this.activeBranchId) return;
    for (const pending of this.pendingOfflineSales) {
      if (
        pending.branch_id !== this.activeBranchId ||
        this.sales.some(
          (sale) =>
            sale.client_request_id === pending.id || sale.id === `offline-${pending.id}`,
        )
      ) {
        continue;
      }
      const payload = pending.payload;
      const barberId =
        typeof payload['barber_id'] === 'string' ? payload['barber_id'] : null;
      const product = payload['sale_kind'] === 'product';
      const serviceId =
        typeof payload['service_id'] === 'string' ? payload['service_id'] : '';
      const customName =
        typeof payload['custom_service_name'] === 'string'
          ? payload['custom_service_name']
          : '';
      const service = this.services.find((item) => item.id === serviceId);
      const barber = this.barbers.find((item) => item.id === barberId);
      const amount = Number(payload['amount'] || 0);
      const listedPrice = product || customName ? null : Number(service?.price || amount);
      const tipAmount = listedPrice ? Math.max(0, amount - listedPrice) : 0;
      this.sales.unshift({
        id: `offline-${pending.id}`,
        client_request_id: pending.id,
        created_at: `${payload['sale_date']}T${payload['sale_time']}:00`,
        branch_id: pending.branch_id,
        branch_name: this.activeBranch()?.name || 'Barbería',
        sale_kind: product ? 'product' : 'service',
        barber_id: product ? null : barberId,
        barber_name: product ? 'Barbería · Nevera' : barber?.name || 'Barbero',
        service_id: product ? 'nevera' : serviceId || 'especial',
        service_name: customName || service?.name || 'Venta pendiente',
        amount,
        base_amount: amount - tipAmount,
        listed_price: listedPrice,
        tip_amount: tipAmount,
        payment_method: payload['payment_method'] === 'nequi' ? 'nequi' : 'cash',
        proof_note:
          typeof payload['proof_note'] === 'string' ? payload['proof_note'] : '',
        client_name:
          typeof payload['client_name'] === 'string' ? payload['client_name'] : '',
        status: 'sync_pending',
      });
    }
  }

  private resetSaleAfterSave(): void {
    this.saleForm.client_name = '';
    this.saleForm.proof_note = '';
    this.proofDataUrl = '';
    this.proofPreviewUrl = '';
    this.specialServiceName = '';
    if (this.saleKind === 'service' && this.services.length) this.selectService(this.services[0]);
  }

  private isReconnectableError(error: unknown): boolean {
    return error instanceof ApiRequestError && error.reconnectable;
  }

  async flushOfflineSales(): Promise<void> {
    if (
      this.syncingOfflineSales ||
      !this.activeBranchId ||
      !this.pendingOfflineSales.some((item) => item.branch_id === this.activeBranchId)
    ) {
      return;
    }
    this.syncingOfflineSales = true;
    this.offlineSyncMessage = 'Reconexión disponible. Sincronizando ventas pendientes...';
    this.offlineSyncMessageType = '';
    let synchronized = 0;
    try {
      for (const pending of [...this.pendingOfflineSales]) {
        if (pending.branch_id !== this.activeBranchId) continue;
        const syncController = new AbortController();
        const syncTimeout = window.setTimeout(() => syncController.abort(), 10000);
        try {
          await this.api('/api/sales', {
            method: 'POST',
            body: JSON.stringify(pending.payload),
            signal: syncController.signal,
          });
          this.pendingOfflineSales = this.pendingOfflineSales.filter(
            (item) => item.id !== pending.id,
          );
          this.persistOfflineSales();
          synchronized += 1;
        } catch (error) {
          if (this.isReconnectableError(error)) {
            this.realtimeConnected = false;
            this.offlineSyncMessage =
              'Servidor no disponible. Las ventas continúan guardadas en este dispositivo.';
            this.offlineSyncMessageType = '';
            break;
          }
          pending.last_error = this.errorMessage(error);
          this.persistOfflineSales();
          this.offlineSyncMessage =
            `Una venta pendiente necesita revisión: ${pending.last_error}`;
          this.offlineSyncMessageType = 'error';
          break;
        } finally {
          window.clearTimeout(syncTimeout);
        }
      }
      if (synchronized) {
        this.offlineSyncMessage =
          `${synchronized} venta${synchronized === 1 ? '' : 's'} sincronizada${synchronized === 1 ? '' : 's'} correctamente.`;
        this.offlineSyncMessageType = 'success';
        await this.loadData(true);
      } else {
        this.applyOfflineSalesToView();
      }
    } finally {
      this.syncingOfflineSales = false;
      this.renderNow();
    }
  }

  connectRealtime(): void {
    if (!('EventSource' in window)) return;
    const params = new URLSearchParams({ device_id: this.adminDeviceId });
    if (this.adminToken) params.set('token', this.adminToken);
    this.eventSource = new EventSource(`/api/events?${params.toString()}`);
    this.eventSource.addEventListener('open', () => {
      this.realtimeConnected = true;
      void this.flushOfflineSales();
      this.renderNow();
    });
    this.eventSource.addEventListener('db-changed', () => {
      this.realtimeConnected = true;
      if (this.realtimeRefreshTimer) window.clearTimeout(this.realtimeRefreshTimer);
      this.realtimeRefreshTimer = window.setTimeout(() => {
        if (this.activeBranchId) this.loadData(true);
        else this.loadAdminOptions(true);
      }, 250);
    });
    this.eventSource.addEventListener('error', () => {
      this.realtimeConnected = false;
      this.renderNow();
    });
  }

  async updateSaleStatus(saleId: string, status: SaleStatus): Promise<void> {
    try {
      await this.api(`/api/sales/${saleId}/status`, {
        method: 'POST',
        body: JSON.stringify({ status }),
      });
      await this.loadData(true);
    } catch (error) {
      window.alert(this.errorMessage(error));
    }
  }

  startEditSale(sale: Sale, context: 'history' | 'accounting' = 'history'): void {
    this.editingSale = sale;
    this.saleEditContext = context;
    this.editSaleForm = {
      barber_id: sale.barber_id || '',
      service_name: sale.service_name,
      amount: sale.amount,
      payment_method: sale.payment_method,
      client_name: sale.client_name || '',
      proof_note: sale.proof_note || '',
    };
    if (context === 'accounting') {
      this.accountingMovementMessage = '';
    } else {
      this.historyActionMessage = '';
    }
    window.setTimeout(() => {
      document.getElementById(
        context === 'accounting' ? 'accounting-sale-editor' : 'history-sale-editor',
      )?.scrollIntoView({
        behavior: 'smooth',
        block: 'center',
      });
    });
  }

  cancelSaleEdit(): void {
    this.editingSale = null;
  }

  barberIsAvailable(barberId: string | null): boolean {
    return !!barberId && this.barbers.some((barber) => barber.id === barberId);
  }

  async saveSaleEdit(): Promise<void> {
    if (!this.editingSale || this.historySaleSaving) return;
    const editingProduct = this.isProductSale(this.editingSale);
    this.historySaleSaving = true;
    try {
      await this.api(`/api/sales/${this.editingSale.id}`, {
        method: 'POST',
        body: JSON.stringify(this.editSaleForm),
      });
      this.editingSale = null;
      if (this.saleEditContext === 'accounting') {
        this.accountingMovementMessage = 'Movimiento modificado correctamente.';
        this.accountingMovementMessageType = 'success';
      } else {
        this.historyActionMessage = editingProduct
          ? 'Venta de nevera modificada correctamente.'
          : 'Corte modificado correctamente.';
        this.historyActionMessageType = 'success';
      }
      await this.loadData(true);
    } catch (error) {
      if (this.saleEditContext === 'accounting') {
        this.accountingMovementMessage = this.errorMessage(error);
        this.accountingMovementMessageType = 'error';
      } else {
        this.historyActionMessage = this.errorMessage(error);
        this.historyActionMessageType = 'error';
      }
    } finally {
      this.historySaleSaving = false;
      this.renderNow();
    }
  }

  async deleteSale(
    sale: Sale,
    context: 'history' | 'accounting' = 'history',
  ): Promise<void> {
    const inAccounting = context === 'accounting';
    const confirmed = window.confirm(
      `¿Eliminar este ${inAccounting ? 'movimiento diario' : this.isProductSale(sale) ? 'producto del historial' : 'corte del historial'}?\n\n${this.saleDay(sale)} · ${this.saleResponsibleLabel(sale)} · ${sale.service_name} · ${this.formatMoney(sale.amount)}\n\nEsta acción no se puede deshacer.`,
    );
    if (!confirmed) return;

    try {
      await this.api(`/api/sales/${sale.id}/delete`, {
        method: 'POST',
        body: JSON.stringify({}),
      });
      if (this.editingSale?.id === sale.id) this.editingSale = null;
      if (inAccounting) {
        this.accountingMovementMessage = 'Movimiento eliminado correctamente.';
        this.accountingMovementMessageType = 'success';
      } else {
        this.historyActionMessage = 'Corte eliminado correctamente.';
        this.historyActionMessageType = 'success';
      }
      await this.loadData(true);
    } catch (error) {
      if (inAccounting) {
        this.accountingMovementMessage = this.errorMessage(error);
        this.accountingMovementMessageType = 'error';
      } else {
        this.historyActionMessage = this.errorMessage(error);
        this.historyActionMessageType = 'error';
      }
      this.renderNow();
    }
  }

  startShiftAmountEdit(sale: Sale): void {
    this.editingShiftSaleId = sale.id;
    this.editingShiftAmount = sale.amount;
    this.shiftActionMessage = '';
  }

  cancelShiftAmountEdit(): void {
    this.editingShiftSaleId = '';
    this.editingShiftAmount = 0;
  }

  async confirmShiftAmountEdit(sale: Sale): Promise<void> {
    if (this.shiftSaleSaving) return;
    if (Number(this.editingShiftAmount) <= 0) {
      this.shiftActionMessage = 'El valor debe ser mayor a cero.';
      this.shiftActionMessageType = 'error';
      return;
    }

    this.shiftSaleSaving = true;
    try {
      await this.api(`/api/sales/${sale.id}`, {
        method: 'POST',
        body: JSON.stringify({
          barber_id: sale.barber_id,
          service_name: sale.service_name,
          amount: Number(this.editingShiftAmount),
          payment_method: sale.payment_method,
          client_name: sale.client_name || '',
          proof_note: sale.proof_note || '',
        }),
      });
      this.cancelShiftAmountEdit();
      this.shiftActionMessage = this.isProductSale(sale)
        ? 'Valor del producto modificado correctamente.'
        : 'Valor del corte modificado correctamente.';
      this.shiftActionMessageType = 'success';
      await this.loadData(true);
    } catch (error) {
      this.shiftActionMessage = this.errorMessage(error);
      this.shiftActionMessageType = 'error';
    } finally {
      this.shiftSaleSaving = false;
      this.renderNow();
    }
  }

  async deleteShiftSale(sale: Sale): Promise<void> {
    const confirmed = window.confirm(
      `¿Eliminar esta ${this.isProductSale(sale) ? 'venta de nevera' : 'venta del resumen de turno'}?\n\n${this.saleResponsibleLabel(sale)} · ${sale.service_name} · ${this.formatMoney(sale.amount)}\n\nEsta acción no se puede deshacer.`,
    );
    if (!confirmed) return;

    try {
      await this.api(`/api/sales/${sale.id}/delete`, {
        method: 'POST',
        body: JSON.stringify({}),
      });
      if (this.editingShiftSaleId === sale.id) this.cancelShiftAmountEdit();
      this.shiftActionMessage = this.isProductSale(sale)
        ? 'Venta de nevera eliminada correctamente.'
        : 'Corte eliminado correctamente.';
      this.shiftActionMessageType = 'success';
      await this.loadData(true);
    } catch (error) {
      this.shiftActionMessage = this.errorMessage(error);
      this.shiftActionMessageType = 'error';
      this.renderNow();
    }
  }

  async closeDay(): Promise<void> {
    try {
      const result = await this.api<{ backup_date?: string }>('/api/day/close', {
        method: 'POST',
        body: JSON.stringify({
          branch_id: this.activeBranchId,
          counted_cash: Number(this.countedCash || 0),
        }),
      });
      this.showCloseMessage(
        `Caja de ${this.activeBranch()?.name} cerrada. El respaldo de GitHub se está enviando en segundo plano.`,
        'success',
      );
      this.startBackupProgress(result.backup_date || this.todayKey(), 'close');
      await this.loadData(true);
    } catch (error) {
      this.showCloseMessage(this.errorMessage(error), 'error');
    }
  }

  async reopenDay(): Promise<void> {
    if (!window.confirm(`¿Reabrir la caja de ${this.activeBranch()?.name}?`)) return;
    try {
      const result = await this.api<{ backup_date?: string }>('/api/day/reopen', {
        method: 'POST',
        body: JSON.stringify({ branch_id: this.activeBranchId }),
      });
      this.showCloseMessage('Caja reabierta. Actualizando el respaldo de GitHub.', 'success');
      this.startBackupProgress(result.backup_date || this.todayKey(), 'reopen');
      await this.loadData(true);
    } catch (error) {
      this.showCloseMessage(this.errorMessage(error), 'error');
    }
  }

  private startBackupProgress(
    dateKey: string,
    context: 'close' | 'reopen' | 'manual',
  ): void {
    if (this.backupStatusTimer) window.clearInterval(this.backupStatusTimer);
    this.backupTargetDate = dateKey;
    this.backupProgressContext = context;
    this.backupProgressVisible = true;
    this.backupProgressState = 'queued';
    this.backupProgress = 15;
    this.backupProgressMessage = 'Preparando el respaldo y esperando el turno de subida...';
    this.backupStatusBusy = false;
    void this.refreshBackupProgress();
    this.backupStatusTimer = window.setInterval(() => {
      void this.refreshBackupProgress();
    }, 1200);
  }

  private async refreshBackupProgress(): Promise<void> {
    if (this.backupStatusBusy || !this.backupProgressVisible) return;
    this.backupStatusBusy = true;
    try {
      const response = await this.api<{ status: HistoryBackupStatus }>(
        '/api/history-backup-status',
      );
      const status = response.status || {};
      if (status.date && status.date !== this.backupTargetDate) {
        this.backupProgressState = 'queued';
        this.backupProgress = Math.min(30, Math.max(this.backupProgress, 20));
        this.backupProgressMessage = `Terminando un respaldo anterior (${status.date})...`;
        return;
      }

      if (status.state === 'uploading') {
        this.backupProgressState = 'uploading';
        this.backupProgress = Math.min(90, Math.max(42, this.backupProgress + 6));
        this.backupProgressMessage = status.message || 'Subiendo el historial a GitHub...';
      } else if (status.state === 'success') {
        this.backupProgressState = 'success';
        this.backupProgress = 100;
        this.backupProgressMessage =
          status.message || 'El respaldo se subió correctamente a GitHub.';
        if (this.backupProgressContext === 'manual') {
          this.historyBackupMessage = `Los datos del ${this.backupTargetDate} se subieron correctamente a GitHub.`;
          this.historyBackupMessageType = 'success';
        } else {
          this.closeMessage =
            this.backupProgressContext === 'reopen'
              ? 'La caja quedó reabierta y el respaldo se actualizó correctamente en GitHub.'
              : `Caja de ${this.activeBranch()?.name} cerrada y respaldada correctamente en GitHub.`;
          this.closeMessageType = 'success';
        }
        this.stopBackupProgressPolling();
      } else if (status.state === 'error') {
        this.backupProgressState = 'error';
        this.backupProgress = 100;
        this.backupProgressMessage = status.message || 'GitHub rechazó el respaldo.';
        if (this.backupProgressContext === 'manual') {
          this.historyBackupMessage = `No se pudieron subir los datos: ${this.backupProgressMessage}`;
          this.historyBackupMessageType = 'error';
        } else {
          this.closeMessage = `La caja quedó guardada localmente, pero el respaldo de GitHub falló: ${this.backupProgressMessage}`;
          this.closeMessageType = 'error';
        }
        this.stopBackupProgressPolling();
      } else {
        this.backupProgressState = 'queued';
        this.backupProgress = Math.min(35, Math.max(this.backupProgress, 18));
        this.backupProgressMessage =
          status.message || 'El respaldo está esperando para comenzar.';
      }
    } catch (error) {
      this.backupProgressState = 'error';
      this.backupProgress = 100;
      this.backupProgressMessage = this.errorMessage(error);
      if (this.backupProgressContext === 'manual') {
        this.historyBackupMessage = `No se pudo consultar el estado del respaldo: ${this.backupProgressMessage}`;
        this.historyBackupMessageType = 'error';
      } else {
        this.closeMessage =
          'La caja quedó guardada localmente, pero no se pudo consultar el respaldo.';
        this.closeMessageType = 'error';
      }
      this.stopBackupProgressPolling();
    } finally {
      this.backupStatusBusy = false;
      this.renderNow();
    }
  }

  private stopBackupProgressPolling(): void {
    if (this.backupStatusTimer) {
      window.clearInterval(this.backupStatusTimer);
      this.backupStatusTimer = undefined;
    }
  }

  async handleProofFile(event: Event): Promise<void> {
    const input = event.target as HTMLInputElement;
    const file = input.files?.[0];
    if (!file) return;
    if (!file.type.startsWith('image/')) {
      this.showSaleMessage('Selecciona una imagen.', 'error');
      return;
    }
    this.proofProcessing = true;
    this.saleMessage = 'Optimizando el comprobante para enviarlo más rápido…';
    this.saleMessageType = '';
    this.renderNow();
    try {
      const dataUrl = await this.readImage(file);
      this.proofDataUrl = dataUrl;
      this.proofPreviewUrl = dataUrl;
      this.showSaleMessage('Comprobante listo para enviar.', 'success');
    } catch (error) {
      this.showSaleMessage(this.errorMessage(error), 'error');
    } finally {
      this.proofProcessing = false;
      input.value = '';
      this.renderNow();
    }
  }

  todayKey(): string {
    const now = new Date();
    const month = String(now.getMonth() + 1).padStart(2, '0');
    const day = String(now.getDate()).padStart(2, '0');
    return `${now.getFullYear()}-${month}-${day}`;
  }

  saleDay(sale: Sale): string {
    return String(sale.created_at || '').slice(0, 10);
  }

  timeOnly(value: string): string {
    const match = String(value || '').match(/T(\d{2}):(\d{2})/);
    if (!match) return '--:--';
    const hour = Number(match[1]);
    const period = hour >= 12 ? 'p. m.' : 'a. m.';
    return `${hour % 12 || 12}:${match[2]} ${period}`;
  }

  formatMoney(value: number): string {
    return new Intl.NumberFormat('es-CO', {
      style: 'currency',
      currency: 'COP',
      maximumFractionDigits: 0,
    }).format(Number(value || 0));
  }

  paymentLabel(method: PaymentMethod): string {
    return method === 'nequi' ? 'Nequi' : 'Efectivo';
  }

  statusLabel(status: string): string {
    const labels: Record<string, string> = {
      confirmed: 'Confirmada',
      pending_review: 'Pendiente',
      rejected: 'Rechazada',
      annulled: 'Anulada',
      sync_pending: 'Por sincronizar',
      scheduled: 'Agendada',
      cancelled: 'Cancelada',
      closed: 'Cerrado',
      reopened: 'Reabierto',
    };
    return labels[status] || status;
  }

  branchSales(): Sale[] {
    return this.sales.filter((sale) => sale.branch_id === this.activeBranchId);
  }

  activeSales(): Sale[] {
    return this.branchSales().filter(
      (sale) =>
        this.saleDay(sale) === this.todayKey() &&
        sale.status !== 'annulled' &&
        sale.status !== 'rejected',
    );
  }

  confirmedSales(): Sale[] {
    return this.activeSales().filter((sale) => sale.status === 'confirmed');
  }

  selectedBarber(): Barber | undefined {
    return this.barbers.find((barber) => barber.id === this.saleForm.barber_id);
  }

  selectedBarberSales(): Sale[] {
    return this.activeSales().filter((sale) => sale.barber_id === this.saleForm.barber_id);
  }

  fridgeSales(): Sale[] {
    return this.activeSales().filter((sale) => this.isProductSale(sale));
  }

  shiftSummarySales(): Sale[] {
    return this.saleKind === 'product' ? this.fridgeSales() : this.selectedBarberSales();
  }

  shiftSummaryTitle(): string {
    return this.saleKind === 'product'
      ? 'Nevera de la barbería'
      : this.selectedBarber()?.name || 'Barbero';
  }

  shiftSummaryTotal(): number {
    return this.sum(this.shiftSummarySales());
  }

  shiftSummaryCash(): number {
    return this.sum(this.shiftSummarySales().filter((sale) => sale.payment_method === 'cash'));
  }

  shiftSummaryNequi(): number {
    return this.sum(this.shiftSummarySales().filter((sale) => sale.payment_method === 'nequi'));
  }

  selectedBarberTotal(): number {
    return this.sum(this.selectedBarberSales());
  }

  selectedBarberCash(): number {
    return this.sum(this.selectedBarberSales().filter((sale) => sale.payment_method === 'cash'));
  }

  selectedBarberNequi(): number {
    return this.sum(this.selectedBarberSales().filter((sale) => sale.payment_method === 'nequi'));
  }

  expectedCash(): number {
    return this.sum(this.confirmedSales().filter((sale) => sale.payment_method === 'cash'));
  }

  nequiConfirmed(): number {
    return this.sum(this.confirmedSales().filter((sale) => sale.payment_method === 'nequi'));
  }

  nequiPending(): number {
    return this.sum(this.activeSales().filter((sale) => sale.status === 'pending_review'));
  }

  totalConfirmed(): number {
    return this.sum(this.confirmedSales());
  }

  pendingReviewSales(): Sale[] {
    return this.branchSales().filter((sale) => sale.status === 'pending_review');
  }

  salesForDate(dateKey: string, branchId = this.activeBranchId): Sale[] {
    return this.sales.filter((sale) => this.saleDay(sale) === dateKey && sale.branch_id === branchId);
  }

  confirmedSalesForDate(dateKey: string, branchId = this.activeBranchId): Sale[] {
    return this.salesForDate(dateKey, branchId).filter((sale) => sale.status === 'confirmed');
  }

  accountingAllSales(): Sale[] {
    return this.salesForDate(this.accountingDate);
  }

  accountingSales(): Sale[] {
    const sales = [...this.accountingAllSales()].sort((left, right) => {
      const byTime = String(left.created_at || '').localeCompare(String(right.created_at || ''));
      return byTime || String(left.id || '').localeCompare(String(right.id || ''));
    });
    if (this.accountingBarberFilterId === 'all') return sales;
    return sales.filter((sale) => sale.barber_id === this.accountingBarberFilterId);
  }

  accountingConfirmedSales(): Sale[] {
    return this.accountingSales().filter((sale) => sale.status === 'confirmed');
  }

  accountingProductMovements(): Sale[] {
    return this.accountingSales().filter((sale) => this.isProductSale(sale));
  }

  accountingServiceMovements(): Sale[] {
    return this.accountingSales().filter((sale) => !this.isProductSale(sale));
  }

  accountingTotal(): number {
    return this.sum(this.accountingConfirmedSales());
  }

  accountingCash(): number {
    return this.sum(
      this.accountingConfirmedSales().filter((sale) => sale.payment_method === 'cash'),
    );
  }

  accountingNequi(): number {
    return this.sum(
      this.accountingConfirmedSales().filter((sale) => sale.payment_method === 'nequi'),
    );
  }

  accountingPendingSales(): Sale[] {
    return this.accountingSales().filter((sale) => sale.status === 'pending_review');
  }

  accountingPendingTotal(): number {
    return this.sum(this.accountingPendingSales());
  }

  selectAccountingBarberFilter(barberId: string): void {
    this.accountingBarberFilterId = barberId;
    this.accountingMovementMessage = '';
    if (this.saleEditContext === 'accounting') this.editingSale = null;
    if (barberId !== 'all') {
      this.accountingSaleForm.barber_id = barberId;
      this.newExpense.expense_type = 'barber';
      this.newExpense.barber_id = barberId;
    }
  }

  accountingFilterLabel(): string {
    if (this.accountingBarberFilterId === 'all') return 'Toda la barbería';
    return (
      this.barbers.find((barber) => barber.id === this.accountingBarberFilterId)?.name ||
      'Barbero'
    );
  }

  accountingVisibleBarbers(): Barber[] {
    if (this.accountingBarberFilterId === 'all') return this.barbers;
    return this.barbers.filter((barber) => barber.id === this.accountingBarberFilterId);
  }

  selectAccountingDate(dateKey: string): void {
    this.accountingDate = dateKey;
    this.accountingSaleFormOpen = false;
    this.accountingSaleMessage = '';
    if (this.saleEditContext === 'accounting') this.editingSale = null;
  }

  openAccountingSaleForm(): void {
    this.accountingSaleFormOpen = true;
    this.accountingSaleMessage = '';
    if (this.accountingDate !== this.todayKey() && !this.supportsHistoricalSales) {
      this.accountingSaleMessage =
        'El servidor abierto todavía no admite fechas anteriores. Reinicia el programa antes de registrar este día.';
      this.accountingSaleMessageType = 'error';
    }
    if (!this.accountingSaleForm.sale_time) {
      const now = new Date();
      this.accountingSaleForm.sale_time =
        `${String(now.getHours()).padStart(2, '0')}:${String(now.getMinutes()).padStart(2, '0')}`;
    }
    this.ensureDefaults();
  }

  closeAccountingSaleForm(): void {
    this.accountingSaleFormOpen = false;
    this.accountingSaleMessage = '';
  }

  selectAccountingService(serviceId: string): void {
    this.accountingSaleKind = 'service';
    this.accountingSaleForm.service_id = serviceId;
    this.accountingCustomServiceName = '';
    const service = this.services.find((item) => item.id === serviceId);
    this.accountingSaleForm.amount = service?.price || 0;
  }

  accountingSpecialService(): boolean {
    return this.accountingSaleForm.service_id === 'especial';
  }

  selectAccountingSaleKind(kind: SaleKind): void {
    this.accountingSaleKind = kind;
    this.accountingSaleMessage = '';
    if (kind === 'product') {
      if (!this.accountingFridgeProductName.trim()) this.accountingFridgeProductName = 'Agua';
      this.accountingSaleForm.amount = 0;
      return;
    }
    const service = this.services[0];
    this.accountingSaleForm.service_id = service?.id || '';
    this.accountingSaleForm.amount = service?.price || 0;
  }

  async handleAccountingProofFile(event: Event): Promise<void> {
    const input = event.target as HTMLInputElement;
    const file = input.files?.[0];
    if (!file) return;
    if (!file.type.startsWith('image/')) {
      this.accountingSaleMessage = 'Selecciona una imagen.';
      this.accountingSaleMessageType = 'error';
      input.value = '';
      return;
    }
    try {
      const dataUrl = await this.readImage(file);
      this.accountingProofDataUrl = dataUrl;
      this.accountingProofPreviewUrl = dataUrl;
    } catch (error) {
      this.accountingSaleMessage = this.errorMessage(error);
      this.accountingSaleMessageType = 'error';
    } finally {
      input.value = '';
      this.renderNow();
    }
  }

  async submitAccountingSale(): Promise<void> {
    if (this.accountingSaleSaving) return;
    if (this.accountingDate !== this.todayKey() && !this.supportsHistoricalSales) {
      this.accountingSaleMessage =
        'No se guardó el corte: reinicia el programa para activar la separación correcta por fechas.';
      this.accountingSaleMessageType = 'error';
      return;
    }
    if (
      this.accountingSaleKind === 'service' &&
      (!this.accountingSaleForm.barber_id || !this.accountingSaleForm.service_id)
    ) {
      this.accountingSaleMessage = 'Selecciona el barbero y el servicio.';
      this.accountingSaleMessageType = 'error';
      return;
    }
    if (
      this.accountingSaleKind === 'service' &&
      this.accountingSpecialService() &&
      this.accountingCustomServiceName.trim().length < 2
    ) {
      this.accountingSaleMessage = 'Escribe el nombre del servicio especial.';
      this.accountingSaleMessageType = 'error';
      return;
    }
    if (
      this.accountingSaleKind === 'product' &&
      this.accountingFridgeProductName.trim().length < 2
    ) {
      this.accountingSaleMessage = 'Escribe el nombre del producto de la nevera.';
      this.accountingSaleMessageType = 'error';
      return;
    }
    if (Number(this.accountingSaleForm.amount) <= 0) {
      this.accountingSaleMessage = 'El valor cobrado debe ser mayor a cero.';
      this.accountingSaleMessageType = 'error';
      return;
    }
    if (
      this.accountingSaleForm.payment_method === 'nequi' &&
      !this.accountingProofDataUrl
    ) {
      this.accountingSaleMessage = 'Sube el comprobante de Nequi.';
      this.accountingSaleMessageType = 'error';
      return;
    }

    this.accountingSaleSaving = true;
    try {
      const result = await this.api<{ sale: Sale }>('/api/sales', {
        method: 'POST',
        body: JSON.stringify({
          branch_id: this.activeBranchId,
          sale_kind: this.accountingSaleKind,
          barber_id:
            this.accountingSaleKind === 'product'
              ? null
              : this.accountingSaleForm.barber_id,
          service_id: this.accountingSaleKind === 'product' || this.accountingSpecialService()
            ? ''
            : this.accountingSaleForm.service_id,
          custom_service_name:
            this.accountingSaleKind === 'product'
              ? this.accountingFridgeProductName.trim()
              : this.accountingSpecialService()
                ? this.accountingCustomServiceName.trim()
                : '',
          amount: Number(this.accountingSaleForm.amount),
          payment_method: this.accountingSaleForm.payment_method,
          proof_image: this.accountingProofDataUrl,
          proof_note: this.accountingSaleForm.proof_note,
          client_name: this.accountingSaleForm.client_name,
          sale_date: this.accountingDate,
          sale_time: this.accountingSaleForm.sale_time,
        }),
      });
      if (this.saleDay(result.sale) !== this.accountingDate) {
        throw new Error(
          `El servidor devolvió la fecha ${this.saleDay(result.sale)} en lugar de ${this.accountingDate}. Reinicia el programa antes de continuar.`,
        );
      }
      this.accountingSaleForm.client_name = '';
      this.accountingSaleForm.proof_note = '';
      this.accountingProofDataUrl = '';
      this.accountingProofPreviewUrl = '';
      this.accountingCustomServiceName = '';
      this.accountingSaleMessage =
        this.accountingSaleKind === 'product'
          ? `Venta de nevera agregada al ${this.accountingDate}.`
          : `Corte agregado a la facturación del ${this.accountingDate}.`;
      this.accountingSaleMessageType = 'success';
      await this.loadData(true);
    } catch (error) {
      this.accountingSaleMessage = this.errorMessage(error);
      this.accountingSaleMessageType = 'error';
    } finally {
      this.accountingSaleSaving = false;
      this.renderNow();
    }
  }

  changeAccountingMonth(offset: number): void {
    const [year, month] = this.accountingMonthKey.split('-').map(Number);
    const changed = new Date(year, month - 1 + offset, 1);
    this.accountingMonthKey = `${changed.getFullYear()}-${String(changed.getMonth() + 1).padStart(2, '0')}`;
  }

  accountingMonthLabel(): string {
    const [year, month] = this.accountingMonthKey.split('-').map(Number);
    const label = new Intl.DateTimeFormat('es-CO', {
      month: 'long',
      year: 'numeric',
    }).format(new Date(year, month - 1, 1));
    return label.charAt(0).toUpperCase() + label.slice(1);
  }

  accountingCalendarDays(): CalendarDay[] {
    const [year, month] = this.accountingMonthKey.split('-').map(Number);
    const firstDay = new Date(year, month - 1, 1);
    const daysInMonth = new Date(year, month, 0).getDate();
    const leadingBlanks = (firstDay.getDay() + 6) % 7;
    const days: CalendarDay[] = [];

    for (let index = 0; index < leadingBlanks; index++) {
      days.push({
        key: `blank-${index}`,
        day: 0,
        inMonth: false,
        hasSales: false,
        isFuture: false,
      });
    }

    for (let day = 1; day <= daysInMonth; day++) {
      const key = `${year}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
      const hasSales = this.salesForDate(key).some(
        (sale) => sale.status !== 'annulled' && sale.status !== 'rejected',
      );
      days.push({
        key,
        day,
        inMonth: true,
        hasSales,
        isFuture: key > this.todayKey(),
      });
    }

    return days;
  }

  accountingBarberTotal(barberId: string): number {
    return this.sum(
      this.accountingConfirmedSales().filter((sale) => sale.barber_id === barberId),
    );
  }

  accountingBarberCount(barberId: string): number {
    return this.accountingConfirmedSales().filter((sale) => sale.barber_id === barberId).length;
  }

  accountingBarberTip(barberId: string): number {
    return this.accountingConfirmedSales()
      .filter((sale) => sale.barber_id === barberId)
      .reduce((total, sale) => total + this.saleTip(sale), 0);
  }

  accountingBarberBaseTotal(barberId: string): number {
    return this.accountingConfirmedSales()
      .filter((sale) => sale.barber_id === barberId)
      .reduce((total, sale) => total + this.saleBase(sale), 0);
  }

  accountingBarberCommission(barberId: string): number {
    return (
      Math.round(this.accountingBarberBaseTotal(barberId) * this.barberCommissionRate(barberId)) +
      this.accountingBarberTip(barberId)
    );
  }

  accountingBarberNequi(barberId: string): number {
    return this.accountingBarberNequiSales(barberId).reduce(
      (total, sale) => total + Number(sale.amount || 0),
      0,
    );
  }

  accountingBarberNequiSales(barberId: string): Sale[] {
    return this.accountingConfirmedSales().filter(
      (sale) => sale.barber_id === barberId && sale.payment_method === 'nequi',
    );
  }

  accountingBarberCashSales(barberId: string): Sale[] {
    return this.accountingConfirmedSales().filter(
      (sale) => sale.barber_id === barberId && sale.payment_method === 'cash',
    );
  }

  accountingBarberCash(barberId: string): number {
    return this.accountingBarberCashSales(barberId).reduce(
      (total, sale) => total + Number(sale.amount || 0),
      0,
    );
  }

  accountingBarberCashShopShare(barberId: string): number {
    const cashBase = this.accountingBarberCashSales(barberId).reduce(
      (total, sale) => total + this.saleBase(sale),
      0,
    );
    const barberShare = Math.round(cashBase * this.barberCommissionRate(barberId));
    return cashBase - barberShare;
  }

  accountingBarberShopShare(barberId: string): number {
    const baseCommission = Math.round(
      this.accountingBarberBaseTotal(barberId) * this.barberCommissionRate(barberId),
    );
    return this.accountingBarberBaseTotal(barberId) - baseCommission;
  }

  accountingPayrollTotal(): number {
    return this.barbers.reduce(
      (total, barber) => total + this.accountingBarberCommission(barber.id),
      0,
    );
  }

  accountingShopShare(): number {
    return this.accountingTotal() - this.accountingPayrollTotal();
  }

  accountingProductSales(): Sale[] {
    return this.accountingConfirmedSales().filter((sale) => this.isProductSale(sale));
  }

  accountingProductTotal(): number {
    return this.sum(this.accountingProductSales());
  }

  accountingProductCashTotal(): number {
    return this.sum(
      this.accountingProductSales().filter((sale) => sale.payment_method === 'cash'),
    );
  }

  accountingProductNequiTotal(): number {
    return this.sum(
      this.accountingProductSales().filter((sale) => sale.payment_method === 'nequi'),
    );
  }

  expenseType(expense: Expense): 'shop' | 'barber' {
    return expense.expense_type === 'barber' ? 'barber' : 'shop';
  }

  accountingExpenses(): Expense[] {
    return this.expenses
      .filter(
        (expense) =>
          expense.branch_id === this.activeBranchId && expense.date === this.accountingDate,
      )
      .sort((a, b) => b.created_at.localeCompare(a.created_at));
  }

  accountingVisibleExpenses(): Expense[] {
    if (this.accountingBarberFilterId === 'all') return this.accountingExpenses();
    return this.accountingExpenses().filter(
      (expense) =>
        this.expenseType(expense) === 'barber' &&
        expense.barber_id === this.accountingBarberFilterId,
    );
  }

  accountingShopExpenses(): Expense[] {
    return this.accountingExpenses().filter((expense) => this.expenseType(expense) === 'shop');
  }

  accountingBarberExpenses(): Expense[] {
    return this.accountingExpenses().filter(
      (expense) => this.expenseType(expense) === 'barber',
    );
  }

  accountingShopExpenseTotal(): number {
    return this.accountingShopExpenses().reduce(
      (total, expense) => total + Number(expense.amount || 0),
      0,
    );
  }

  accountingBarberDeductionTotal(barberId?: string): number {
    return this.accountingBarberExpenses()
      .filter((expense) => !barberId || expense.barber_id === barberId)
      .reduce((total, expense) => total + Number(expense.amount || 0), 0);
  }

  accountingBarberNet(barberId: string): number {
    return (
      this.accountingBarberCommission(barberId) -
      this.accountingBarberDeductionTotal(barberId)
    );
  }

  accountingShopNetAfterExpenses(): number {
    return (
      this.accountingShopShare() -
      this.accountingShopExpenseTotal() +
      this.accountingBarberDeductionTotal()
    );
  }

  async createExpense(): Promise<void> {
    if (this.expenseSaving) return;
    if (this.newExpense.description.trim().length < 2) {
      this.expenseMessage = 'Escribe el concepto del gasto.';
      this.expenseMessageType = 'error';
      return;
    }
    if (Number(this.newExpense.amount) <= 0) {
      this.expenseMessage = 'El valor del gasto debe ser mayor a cero.';
      this.expenseMessageType = 'error';
      return;
    }
    if (this.newExpense.expense_type === 'barber' && !this.newExpense.barber_id) {
      this.expenseMessage = 'Selecciona el barbero al que se le hará el descuento.';
      this.expenseMessageType = 'error';
      return;
    }
    this.expenseSaving = true;
    try {
      await this.api('/api/expenses', {
        method: 'POST',
        body: JSON.stringify({
          date: this.accountingDate,
          description: this.newExpense.description.trim(),
          amount: Number(this.newExpense.amount),
          expense_type: this.newExpense.expense_type,
          barber_id:
            this.newExpense.expense_type === 'barber' ? this.newExpense.barber_id : '',
        }),
      });
      const savedType = this.newExpense.expense_type;
      this.newExpense = {
        description: '',
        amount: 0,
        expense_type: 'shop',
        barber_id: '',
      };
      this.expenseMessage =
        savedType === 'barber'
          ? `Descuento al barbero agregado al ${this.accountingDate}.`
          : `Gasto de la barbería agregado al ${this.accountingDate}.`;
      this.expenseMessageType = 'success';
      await this.loadData(true);
    } catch (error) {
      this.expenseMessage = this.errorMessage(error);
      this.expenseMessageType = 'error';
    } finally {
      this.expenseSaving = false;
      this.renderNow();
    }
  }

  async deleteExpense(expense: Expense): Promise<void> {
    if (
      !window.confirm(
        `¿Eliminar el gasto "${expense.description}" por ${this.formatMoney(expense.amount)}?`,
      )
    ) {
      return;
    }
    try {
      await this.api(`/api/expenses/${expense.id}/delete`, {
        method: 'POST',
        body: JSON.stringify({}),
      });
      this.expenseMessage = 'Gasto eliminado correctamente.';
      this.expenseMessageType = 'success';
      await this.loadData(true);
    } catch (error) {
      this.expenseMessage = this.errorMessage(error);
      this.expenseMessageType = 'error';
      this.renderNow();
    }
  }

  examinedSales(): Sale[] {
    return this.salesForDate(this.examinedDate, this.examinedBranchId);
  }

  examinedNequiSales(): Sale[] {
    return this.examinedSales().filter((sale) => sale.payment_method === 'nequi');
  }

  examinedProductSales(): Sale[] {
    return this.examinedSales().filter((sale) => this.isProductSale(sale));
  }

  examinedServiceSales(): Sale[] {
    return this.examinedSales().filter((sale) => !this.isProductSale(sale));
  }

  examinedConfirmedProductSales(): Sale[] {
    return this.examinedProductSales().filter((sale) => sale.status === 'confirmed');
  }

  examinedProductTotal(): number {
    return this.sum(this.examinedConfirmedProductSales());
  }

  examinedProductCash(): number {
    return this.sum(
      this.examinedConfirmedProductSales().filter((sale) => sale.payment_method === 'cash'),
    );
  }

  examinedProductNequi(): number {
    return this.sum(
      this.examinedConfirmedProductSales().filter((sale) => sale.payment_method === 'nequi'),
    );
  }

  selectedClosure(): Closure | undefined {
    return this.closures.find(
      (closure) => closure.date === this.examinedDate && closure.branch_id === this.examinedBranchId,
    );
  }

  selectedClosureBarbers(): ClosureBarber[] {
    return this.selectedClosure()?.barbers || [];
  }

  closureBarberRate(barber: ClosureBarber): number {
    const storedRate = Number(barber.commission_rate);
    if (storedRate > 0 && storedRate <= 1) return storedRate;
    return barber.barber_id === 'omar' || barber.barber_name.trim().toLocaleLowerCase('es') === 'omar'
      ? 0.6
      : 0.5;
  }

  closureBarberCommission(barber: ClosureBarber): number {
    const tip = Number(barber.tip_total || 0);
    const base = Number(barber.base_total ?? barber.total - tip);
    return Math.round(base * this.closureBarberRate(barber)) + tip;
  }

  accountingNequiReceivedByBarbers(): number {
    return this.barbers.reduce(
      (total, barber) => total + this.accountingBarberNequi(barber.id),
      0,
    );
  }

  accountingCashShopShareTotal(): number {
    return (
      this.accountingProductCashTotal() +
      this.barbers.reduce(
        (total, barber) => total + this.accountingBarberCashShopShare(barber.id),
        0,
      )
    );
  }

  closureBarberShopShare(barber: ClosureBarber): number {
    const tip = Number(barber.tip_total || 0);
    const base = Number(barber.base_total ?? barber.total - tip);
    return base - Math.round(base * this.closureBarberRate(barber));
  }

  closureBarberNequi(barber: ClosureBarber): number {
    if (barber.nequi_total !== undefined) return Number(barber.nequi_total || 0);
    return this.examinedSales()
      .filter(
        (sale) =>
          sale.status === 'confirmed' &&
          sale.barber_id === barber.barber_id &&
          sale.payment_method === 'nequi',
      )
      .reduce((total, sale) => total + Number(sale.amount || 0), 0);
  }

  closureBarberCash(barber: ClosureBarber): number {
    if (barber.cash_payment_total !== undefined) return Number(barber.cash_payment_total || 0);
    return this.examinedSales()
      .filter(
        (sale) =>
          sale.status === 'confirmed' &&
          sale.barber_id === barber.barber_id &&
          sale.payment_method === 'cash',
      )
      .reduce((total, sale) => total + Number(sale.amount || 0), 0);
  }

  closureBarberCashShopShare(barber: ClosureBarber): number {
    if (barber.cash_shop_share !== undefined) return Number(barber.cash_shop_share || 0);
    const cashBase = this.examinedSales()
      .filter(
        (sale) =>
          sale.status === 'confirmed' &&
          sale.barber_id === barber.barber_id &&
          sale.payment_method === 'cash',
      )
      .reduce((total, sale) => total + this.saleBase(sale), 0);
    return cashBase - Math.round(cashBase * this.closureBarberRate(barber));
  }

  selectExaminedClosure(closure: Closure): void {
    this.examinedDate = closure.date;
    this.examinedBranchId = closure.branch_id;
    this.historyMonthKey = closure.date.slice(0, 7);
  }

  changeHistoryMonth(offset: number): void {
    const [year, month] = this.historyMonthKey.split('-').map(Number);
    const changed = new Date(year, month - 1 + offset, 1);
    this.historyMonthKey = `${changed.getFullYear()}-${String(changed.getMonth() + 1).padStart(2, '0')}`;
  }

  historyMonthLabel(): string {
    const [year, month] = this.historyMonthKey.split('-').map(Number);
    const label = new Intl.DateTimeFormat('es-CO', {
      month: 'long',
      year: 'numeric',
    }).format(new Date(year, month - 1, 1));
    return label.charAt(0).toUpperCase() + label.slice(1);
  }

  historyCalendarDays(): CalendarDay[] {
    const [year, month] = this.historyMonthKey.split('-').map(Number);
    const firstDay = new Date(year, month - 1, 1);
    const daysInMonth = new Date(year, month, 0).getDate();
    const leadingBlanks = (firstDay.getDay() + 6) % 7;
    const billedDates = new Set(
      this.orderedClosures()
        .filter((closure) => closure.date.startsWith(this.historyMonthKey))
        .map((closure) => closure.date),
    );
    for (const sale of this.branchSales()) {
      const dateKey = this.saleDay(sale);
      if (
        dateKey.startsWith(this.historyMonthKey) &&
        sale.status !== 'annulled' &&
        sale.status !== 'rejected'
      ) {
        billedDates.add(dateKey);
      }
    }
    const days: CalendarDay[] = [];
    for (let index = 0; index < leadingBlanks; index++) {
      days.push({
        key: `history-blank-${index}`,
        day: 0,
        inMonth: false,
        hasSales: false,
        isFuture: false,
      });
    }
    for (let day = 1; day <= daysInMonth; day++) {
      const key = `${year}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
      days.push({
        key,
        day,
        inMonth: true,
        hasSales: billedDates.has(key),
        isFuture: key > this.todayKey(),
      });
    }
    return days;
  }

  selectHistoryDate(dateKey: string): void {
    const closure = this.orderedClosures().find((item) => item.date === dateKey);
    if (closure) {
      this.selectExaminedClosure(closure);
      return;
    }
    if (this.salesForDate(dateKey).length) {
      this.examinedDate = dateKey;
      this.examinedBranchId = this.activeBranchId;
      this.historyMonthKey = dateKey.slice(0, 7);
    }
  }

  historyBilledDatesWithoutClosure(): string[] {
    const closedDates = new Set(this.orderedClosures().map((closure) => closure.date));
    return [
      ...new Set(
        this.branchSales()
          .filter(
            (sale) =>
              sale.status !== 'annulled' &&
              sale.status !== 'rejected' &&
              !closedDates.has(this.saleDay(sale)),
          )
          .map((sale) => this.saleDay(sale)),
      ),
    ].sort().reverse();
  }

  historyRecordCount(): number {
    return this.orderedClosures().length + this.historyBilledDatesWithoutClosure().length;
  }

  historyDateTotal(dateKey: string): number {
    return this.sum(this.confirmedSalesForDate(dateKey));
  }

  async loadHistoryBackups(): Promise<void> {
    this.historyBackupLoading = true;
    this.historyBackupMessage = 'Buscando respaldos disponibles en GitHub...';
    this.historyBackupMessageType = '';
    this.renderNow();
    try {
      const result = await this.api<HistoryBackupResponse>('/api/history-backups');
      this.localHistoryMonths = result.local_months || [];
      this.remoteHistoryMonths = result.remote_months || [];
      if (result.remote_error) {
        throw new Error(result.remote_error);
      }

      let downloaded = 0;
      let verified = 0;
      for (let index = 0; index < this.remoteHistoryMonths.length; index++) {
        const month = this.remoteHistoryMonths[index];
        this.historyBackupMessage =
          `Verificando ${month} (${index + 1} de ${this.remoteHistoryMonths.length})...`;
        this.renderNow();
        const monthResult = await this.api<{
          downloaded?: number;
          skipped?: number;
        }>('/api/history-backups/download', {
          method: 'POST',
          body: JSON.stringify({ month }),
        });
        downloaded += Number(monthResult.downloaded || 0);
        verified += Number(monthResult.skipped || 0);
      }

      if (this.remoteHistoryMonths.length) {
        this.localHistoryMonths = [
          ...new Set([...this.localHistoryMonths, ...this.remoteHistoryMonths]),
        ].sort().reverse();
        await this.loadData(true);
        this.historyBackupMessage = downloaded
          ? `${downloaded} respaldo(s) descargado(s) y ${verified} verificado(s) sin duplicar.`
          : `Todo está actualizado: ${verified} respaldo(s) ya estaban verificados en este PC.`;
      } else {
        this.historyBackupMessage = 'Todavía no hay respaldos disponibles en GitHub.';
      }
      this.historyBackupMessageType = 'success';
    } catch (error) {
      this.historyBackupMessage = this.errorMessage(error);
      this.historyBackupMessageType = 'error';
    } finally {
      this.historyBackupLoading = false;
      this.renderNow();
    }
  }

  async uploadTodayHistory(): Promise<void> {
    await this.uploadHistoryDate(this.todayKey());
  }

  async uploadExaminedHistory(): Promise<void> {
    if (!this.examinedDate) return;
    await this.uploadHistoryDate(this.examinedDate);
  }

  async uploadHistoryDate(dateKey: string): Promise<void> {
    if (this.historyUploadLoading || this.backupIsRunning()) return;
    this.historyUploadLoading = true;
    this.historyBackupMessage = `Preparando todos los datos del ${dateKey}...`;
    this.historyBackupMessageType = '';
    this.renderNow();
    try {
      const result = await this.api<{ backup_date?: string; message?: string }>(
        '/api/history-backups/upload',
        {
          method: 'POST',
          body: JSON.stringify({ date: dateKey }),
        },
      );
      const backupDate = result.backup_date || dateKey;
      this.historyBackupMessage =
        result.message || `Datos del ${backupDate} preparados para subir a GitHub.`;
      this.startBackupProgress(backupDate, 'manual');
    } catch (error) {
      const message = this.errorMessage(error);
      this.backupProgressContext = 'manual';
      this.backupProgressVisible = true;
      this.backupProgressState = 'error';
      this.backupProgress = 100;
      this.backupProgressMessage = message;
      this.historyBackupMessage = `No se pudo preparar el respaldo: ${message}`;
      this.historyBackupMessageType = 'error';
    } finally {
      this.historyUploadLoading = false;
      this.renderNow();
    }
  }

  backupIsRunning(): boolean {
    return (
      this.backupProgressVisible &&
      (this.backupProgressState === 'queued' || this.backupProgressState === 'uploading')
    );
  }

  async downloadHistoryMonth(month: string): Promise<void> {
    this.historyBackupLoading = true;
    this.historyBackupMessage = `Descargando ${month}...`;
    this.historyBackupMessageType = '';
    try {
      await this.api('/api/history-backups/download', {
        method: 'POST',
        body: JSON.stringify({ month }),
      });
      this.historyBackupMessage = `Historial de ${month} descargado correctamente.`;
      this.historyBackupMessageType = 'success';
      await this.loadData(true);
      await this.loadHistoryBackups();
      this.historyMonthKey = month;
    } catch (error) {
      this.historyBackupMessage = this.errorMessage(error);
      this.historyBackupMessageType = 'error';
    } finally {
      this.historyBackupLoading = false;
      this.renderNow();
    }
  }

  historyMonthIsLocal(month: string): boolean {
    return this.localHistoryMonths.includes(month);
  }

  closureEvents(closure: Closure): ClosureEvent[] {
    if (closure.events?.length) return closure.events;
    const events: ClosureEvent[] = [];
    if (closure.closed_at) {
      events.push({
        type: 'closed',
        at: closure.closed_at,
        counted_cash: closure.counted_cash,
        expected_cash: closure.expected_cash,
        cash_difference: closure.cash_difference,
        total_confirmed: closure.total_confirmed,
        cash_total: closure.cash_total,
        nequi_confirmed: closure.nequi_confirmed,
        sales_count: closure.sales_count,
      });
    }
    if (closure.reopened_at) events.push({ type: 'reopened', at: closure.reopened_at });
    return events;
  }

  closureEventLabel(event: ClosureEvent): string {
    return event.type === 'closed' ? 'Cierre' : 'Apertura';
  }

  dayTotal(dateKey: string): number {
    return this.sum(this.confirmedSalesForDate(dateKey, this.examinedBranchId));
  }

  dayCash(dateKey: string): number {
    return this.sum(
      this.confirmedSalesForDate(dateKey, this.examinedBranchId).filter(
        (sale) => sale.payment_method === 'cash',
      ),
    );
  }

  dayNequi(dateKey: string): number {
    return this.sum(
      this.confirmedSalesForDate(dateKey, this.examinedBranchId).filter(
        (sale) => sale.payment_method === 'nequi',
      ),
    );
  }

  dayPendingNequi(dateKey: string): number {
    return this.salesForDate(dateKey, this.examinedBranchId).filter(
      (sale) => sale.status === 'pending_review',
    ).length;
  }

  pendingTodayCount(): number {
    return this.activeSales().filter((sale) => sale.status === 'pending_review').length;
  }

  cashDifference(): number {
    const closure = this.currentClosure();
    if (closure?.status === 'closed') return closure.cash_difference;
    return Number(this.countedCash || 0) - this.expectedCash();
  }

  barberTotal(barberId: string): number {
    return this.sum(this.confirmedSales().filter((sale) => sale.barber_id === barberId));
  }

  barberCount(barberId: string): number {
    return this.confirmedSales().filter((sale) => sale.barber_id === barberId).length;
  }

  barberCommission(barberId: string): number {
    const sales = this.confirmedSales().filter((sale) => sale.barber_id === barberId);
    const tips = sales.reduce((total, sale) => total + this.saleTip(sale), 0);
    const base = sales.reduce((total, sale) => total + this.saleBase(sale), 0);
    return Math.round(base * this.barberCommissionRate(barberId)) + tips;
  }

  barberCommissionRate(barberId: string): number {
    const barber = this.barbers.find((item) => item.id === barberId);
    const storedRate = Number(barber?.commission_rate);
    if (storedRate > 0 && storedRate <= 1) return storedRate;
    if (barber?.id === 'omar' || barber?.name.trim().toLocaleLowerCase('es') === 'omar') return 0.6;
    return Number(this.settings.commission_rate || 0.5);
  }

  commissionPercent(barberId: string): number {
    return Math.round(this.barberCommissionRate(barberId) * 100);
  }

  orderedClosures(): Closure[] {
    return [...this.closures]
      .filter((closure) => closure.branch_id === this.activeBranchId)
      .sort((a, b) => `${b.date} ${b.closed_at}`.localeCompare(`${a.date} ${a.closed_at}`));
  }

  orderedBranchClosures(): Closure[] {
    return this.orderedClosures().filter((closure) => closure.branch_id === this.activeBranchId);
  }

  currentClosure(): Closure | undefined {
    return this.closures.find(
      (closure) => closure.date === this.todayKey() && closure.branch_id === this.activeBranchId,
    );
  }

  isCurrentDayClosed(): boolean {
    return this.currentClosure()?.status === 'closed';
  }

  weeklyChart(): ChartPoint[] {
    const points: ChartPoint[] = [];
    const formatter = new Intl.DateTimeFormat('es-CO', { weekday: 'short' });
    for (let offset = 6; offset >= 0; offset--) {
      const date = new Date();
      date.setHours(12, 0, 0, 0);
      date.setDate(date.getDate() - offset);
      const key = this.localDateKey(date);
      points.push({
        key,
        label: formatter.format(date).replace('.', ''),
        value: this.sum(this.confirmedSalesForDate(key)),
        percent: 0,
      });
    }
    const max = Math.max(...points.map((point) => point.value), 1);
    return points.map((point) => ({
      ...point,
      percent: point.value ? Math.max(8, Math.round((point.value / max) * 100)) : 3,
    }));
  }

  serviceChart(): ChartPoint[] {
    const counts = new Map<string, { label: string; value: number }>();
    this.confirmedSales().forEach((sale) => {
      const key = sale.service_name.trim().toLocaleLowerCase('es');
      const current = counts.get(key);
      counts.set(key, {
        label: sale.service_name,
        value: (current?.value || 0) + 1,
      });
    });
    const grouped = [...counts.entries()].map(([key, item]) => ({
      key,
      label: item.label,
      value: item.value,
      percent: 0,
    }));
    const max = Math.max(...grouped.map((point) => point.value), 1);
    return grouped
      .map((point) => ({
        ...point,
        percent: point.value ? Math.max(6, Math.round((point.value / max) * 100)) : 0,
      }))
      .sort((a, b) => b.value - a.value);
  }

  trackById(_index: number, item: { id: string }): string {
    return item.id;
  }

  trackByKey(_index: number, item: { key: string }): string {
    return item.key;
  }

  private localDateKey(date: Date): string {
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');
    return `${date.getFullYear()}-${month}-${day}`;
  }

  private sum(sales: Sale[]): number {
    return sales.reduce((total, sale) => total + Number(sale.amount || 0), 0);
  }

  private async api<T>(path: string, options: RequestInit = {}): Promise<T> {
    const { headers: extraHeaders, signal: suppliedSignal, ...requestOptions } = options;
    const controller = new AbortController();
    const timeout = suppliedSignal ? undefined : window.setTimeout(() => controller.abort(), 45000);
    this.pendingRequests += 1;
    this.networkBusy = true;
    this.renderNow();
    try {
      const response = await fetch(path, {
        ...requestOptions,
        signal: suppliedSignal || controller.signal,
        headers: {
          'Content-Type': 'application/json',
          'X-Branch-Id': this.activeBranchId,
          'X-Admin-Token': this.adminToken,
          'X-Device-Id': this.adminDeviceId,
          ...(extraHeaders || {}),
        },
      });
      const text = await response.text();
      const reconnectableStatus =
        response.status >= 500 ||
        (this.adminRole === 'online' && [404, 408, 425, 429].includes(response.status));
      let data: Record<string, unknown> = {};
      if (text) {
        try {
          data = JSON.parse(text) as Record<string, unknown>;
        } catch {
          if (!response.ok) {
            if ([501, 502, 503, 504].includes(response.status)) {
              throw new ApiRequestError(
                'El enlace online no tiene un servidor conectado. Ejecuta nuevamente “Iniciar Barbería Internet” en el computador principal.',
                response.status,
                true,
              );
            }
            throw new ApiRequestError(
              `El servidor online respondió con un error (${response.status}).`,
              response.status,
              reconnectableStatus,
            );
          }
          throw new ApiRequestError(
            'La respuesta del servidor llegó incompleta. Se intentará nuevamente al reconectar.',
            response.status,
            this.adminRole === 'online',
          );
        }
      }
      if (!response.ok) {
        throw new ApiRequestError(
          typeof data['error'] === 'string'
            ? data['error']
            : `No se pudo completar la acción (${response.status}).`,
          response.status,
          reconnectableStatus,
        );
      }
      return data as T;
    } catch (error) {
      if (error instanceof ApiRequestError) throw error;
      if (error instanceof DOMException && error.name === 'AbortError') {
        throw new ApiRequestError(
          'La conexión está tardando demasiado. Verifica Internet e intenta otra vez.',
          0,
          true,
        );
      }
      if (error instanceof TypeError) {
        throw new ApiRequestError(
          'No hay conexión con el servidor. La venta puede guardarse en modo reconexión.',
          0,
          true,
        );
      }
      throw error;
    } finally {
      if (timeout) window.clearTimeout(timeout);
      this.pendingRequests = Math.max(0, this.pendingRequests - 1);
      this.networkBusy = this.pendingRequests > 0;
      this.renderNow();
    }
  }

  private getAdminDeviceId(): string {
    const storageKey = 'capitan-gold-admin-device-id';
    const isValid = (value: string | null): value is string =>
      Boolean(value && /^[A-Za-z0-9-]{8,80}$/.test(value));
    const create = () =>
      window.crypto?.randomUUID?.() ||
      `${Date.now()}-${Math.random().toString(36).slice(2)}-${Math.random().toString(36).slice(2)}`;
    try {
      const saved = window.localStorage.getItem(storageKey);
      if (isValid(saved)) return saved;
      const created = create();
      window.localStorage.setItem(storageKey, created);
      return created;
    } catch {
      try {
        const saved = window.sessionStorage.getItem(storageKey);
        if (isValid(saved)) return saved;
        const created = create();
        window.sessionStorage.setItem(storageKey, created);
        return created;
      } catch {
        return create();
      }
    }
  }

  private readImage(file: File): Promise<string> {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => {
        const image = new Image();
        image.onload = () => {
          const maxDimension = 1600;
          const scale = Math.min(1, maxDimension / Math.max(image.width, image.height));
          const canvas = document.createElement('canvas');
          canvas.width = Math.max(1, Math.round(image.width * scale));
          canvas.height = Math.max(1, Math.round(image.height * scale));
          const context = canvas.getContext('2d');
          if (!context) {
            reject(new Error('No se pudo preparar la imagen.'));
            return;
          }
          context.fillStyle = '#ffffff';
          context.fillRect(0, 0, canvas.width, canvas.height);
          context.drawImage(image, 0, 0, canvas.width, canvas.height);
          resolve(canvas.toDataURL('image/jpeg', 0.82));
        };
        image.onerror = () => reject(new Error('La imagen seleccionada no se pudo abrir.'));
        image.src = String(reader.result);
      };
      reader.onerror = () => reject(new Error('No se pudo leer la imagen.'));
      reader.readAsDataURL(file);
    });
  }

  private showSaleMessage(text: string, type: 'success' | 'error'): void {
    this.saleMessage = text;
    this.saleMessageType = type;
    this.clearLater(() => {
      this.saleMessage = '';
      this.saleMessageType = '';
    });
  }

  private showCloseMessage(text: string, type: 'success' | 'error'): void {
    this.closeMessage = text;
    this.closeMessageType = type;
    this.clearLater(() => {
      this.closeMessage = '';
      this.closeMessageType = '';
    }, 6000);
  }

  private showInfoMessage(text: string, type: 'success' | 'error'): void {
    this.infoMessage = text;
    this.infoMessageType = type;
    this.clearLater(() => {
      this.infoMessage = '';
      this.infoMessageType = '';
    }, 5000);
  }

  private clearLater(callback: () => void, delay = 3600): void {
    const timer = window.setTimeout(() => {
      callback();
      this.renderNow();
    }, delay);
    this.messageTimers.push(timer);
  }

  private renderNow(): void {
    if (!this.destroyed) this.changeDetector.detectChanges();
  }

  private errorMessage(error: unknown): string {
    return error instanceof Error ? error.message : 'Ocurrió un error inesperado.';
  }
}
