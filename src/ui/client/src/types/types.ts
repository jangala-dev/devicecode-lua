export class Device {
  public modems: Record<string, Modem> = {};
  public net: Record<string, Net> = {};
  public system: System = new System();
  public mcu: Mcu = new Mcu();
  public wifi: Wifi = new Wifi();
}

export class Wifi {
  public users = 0;
}

export class Mcu {
  public temp = 0;
}

export class System {
  public cpu_util = 0;
  public mem_util = 0;
  public temp = 0;
  public fw_id = '';
  public hw_id = '';
  public serial = '';
  public uptime = 0;
  public power = '';
  public battery = '';
}

export class Net {
  public is_online = false;
  public curr_uptime = 0;
  public total_uptime = 0;
}

export class Modem {
  public access_tech = '';
  public access_fam = '';
  public operator = '';
  public sim = '';
  public state = '';
  public signal: Signal[] = [];
  public signal_type = '';
  public band = '';
  public bars = '';
  public wwan_type = '';
  public imei = '';
}

export class Signal {
  public tech = '';
  public type = '';
  public value = '';
  public score = 0;
}

export class Apn {
  public carrier = '';
  public mcc = '';
  public mnc = '';
  public apn = '';
  public type?: string = undefined;
  public protocol?: string = undefined;
  public roaming_protocol?: string = undefined;
  public user_visible?: string = undefined;
  public authtype?: string = undefined;
  public mmsc?: string = undefined;
  public mmsproxy?: string = undefined;
  public mmsport?: string = undefined;
  public proxy?: string = undefined;
  public port?: string = undefined;
  public bearer_bitmask?: string = undefined;
  public read_only?: string = undefined;
  public user?: string = undefined;
  public password?: string = undefined;
  public mvno_type?: string = undefined;
  public mvno_match_data?: string = undefined;
  public mtu?: string = undefined;
  public ppp_number?: string = undefined;
  public vivoentry?: string = undefined;
  public server?: string = undefined;
  public localized_name?: string = undefined;
  public visit_area?: string = undefined;
  public bearer?: string = undefined;
  public profile_id?: string = undefined;
  public modem_cognitive?: string = undefined;
  public max_conns?: string = undefined;
  public max_conns_time?: string = undefined;
  public skip_464xlat?: string = undefined;
  public carrier_enabled?: string = undefined;
  public mtusize?: string = undefined;
  public auth?: string = undefined;
}

export enum LOG_TYPE {
  TRACE = 'TRACE',
  INFO = 'INFO',
  ERROR = 'ERROR',
  WARN = 'WARN',
}

export class LogTypes {
  [LOG_TYPE.TRACE]: boolean;
  [LOG_TYPE.INFO]: boolean;
  [LOG_TYPE.ERROR]: boolean;
  [LOG_TYPE.WARN]: boolean;

  constructor() {
    this[LOG_TYPE.TRACE] = false;
    this[LOG_TYPE.INFO] = false;
    this[LOG_TYPE.ERROR] = false;
    this[LOG_TYPE.WARN] = false;
  }
}
