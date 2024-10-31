## Description
- HAL exposes the interfaces of mmcli for device functionalities such as modem, location, time and sim through creation of subscription services.
- HAL should be as stateless as possible with state only required to prevent hardware level errors

```mermaid
sequenceDiagram
    HAL->>HAL: detect modem with address
    HAL->>HAL: get details
    HAL->>BUS: setup capability endpoints
    HAL->>GSM: hal/modems/mname detected with capabilities

```