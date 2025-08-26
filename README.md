
# MSSQL Dumps Tool

Esta herramienta permite realizar copias de seguridad de bases de datos Microsoft SQL Server, generando un archivo SQL con la estructura de las tablas y los datos en formato de declaraciones INSERT individuales.

## Características

- Conexión a bases de datos Microsoft SQL Server o Azure
- Generación de scripts de creación de tablas (CREATE TABLE)
- Extracción de datos en formato INSERT (un INSERT por registro)
- Soporte para selección específica de tablas
- Manejo correcto de tipos de datos complejos
- Gestión de columnas de identidad (IDENTITY)
- **Verificación de salud robusta** (health check) que comprueba la conexión directamente a la base de datos
- **Soporte para cláusulas WHERE globales** que se aplican a todas las consultas de extracción de datos
- **Soporte para DROP TABLE** con detección automática de sintaxis moderna o legacy según la versión del servidor
- Manejo de errores mejorado y fallback automático para tablas sin datos binarios

## Requisitos

- Bash shell
- Utilidad `sqlcmd` (parte de SQL Server Command Line Tools)
- Acceso a la base de datos Microsoft SQL Server

## Instalación

1. Clone este repositorio:
   ```
   git clone https://github.com/mpernia/mssql-dumps.git
   cd mssql-dumps
   ```

2. Asegúrese de que el script tenga permisos de ejecución:
   ```
   chmod +x mssql_dumps.sh
   ```

3. Si no tiene instalado `sqlcmd`, instálelo según su sistema operativo:

   **Para Ubuntu/Debian:**
   ```
   curl https://packages.microsoft.com/keys/microsoft.asc | sudo apt-key add -
   curl https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/prod.list | sudo tee /etc/apt/sources.list.d/msprod.list
   sudo apt-get update
   sudo apt-get install -y mssql-tools unixodbc-dev
   ```

   **Para macOS:**
   ```
   brew tap microsoft/mssql-release https://github.com/Microsoft/homebrew-mssql-release
   brew update
   brew install mssql-tools
   ```

## Uso

Existen dos formas de proporcionar los parámetros de conexión:

1. **Usando parámetros de línea de comandos**:
   ```
   ./mssql_dumps.sh -S <server> -d <database> -U <username> -P <password> [-o <output_file>] [-t <tables>] [-T <timeout>]
   ```

2. **Usando variables de entorno** (a través de un archivo `.env`):
   ```
   # Crear archivo .env a partir del ejemplo
   cp .env-example .env
   
   # Editar el archivo .env con tus credenciales
   nano .env
   
   # Ejecutar el script (sin parámetros)
   ./mssql_dumps.sh
   ```

### Parámetros y Variables de Entorno

| Parámetro | Variable de entorno | Descripción |
|-----------|---------------------|-------------|
| `-S`      | `MSSQL_SERVER`      | Dirección del servidor Microsoft SQL Server (obligatorio). Formato: `hostname[,port]` |
| `-d`      | `MSSQL_DATABASE`    | Nombre de la base de datos (obligatorio) |
| `-U`      | `MSSQL_USER`        | Nombre de usuario (obligatorio). En Azure SQL suele tener formato `user@servername` |
| `-P`      | `MSSQL_PASSWORD`    | Contraseña (obligatorio) |
| `-o`      | `MSSQL_OUTPUT_FILE` | Archivo de salida (por defecto: backup_YYYYMMDD_HHMMSS.sql) |
| `-t`      | `MSSQL_TABLES`      | Lista de tablas separadas por comas para incluir en el backup |
| `-T`      | `MSSQL_QUERY_TIMEOUT` | Tiempo de espera de la consulta en segundos (por defecto: 0) |
| `-h`      | -                   | Mostrar mensaje de ayuda |
| -         | `MSSQL_DROP_TABLES` | Incluir sentencias DROP TABLE IF EXISTS antes de cada CREATE TABLE. Valores aceptados: true, verdadero, si, yes, 1 |
| -         | `MSSQL_GLOBAL_WHERE_CLAUSE` | Cláusula WHERE opcional que se aplica a todas las consultas SELECT de datos (ej: "IsActive = 1") |

> **Nota**: Los parámetros de línea de comandos tienen precedencia sobre las variables de entorno.

### Ejemplos

**Backup de todas las tablas usando parámetros:**
```
./mssql_dumps.sh -S server.database.windows.net -d myDatabase -U myUser -P myPassword
```

**Backup de tablas específicas:**
```
./mssql_dumps.sh -S server.database.windows.net -d myDatabase -U myUser -P myPassword -t dbo.Customers,dbo.Products
```

**Especificar archivo de salida:**
```
./mssql_dumps.sh -S server.database.windows.net -d myDatabase -U myUser -P myPassword -o backup_customers.sql
```

**Usando cláusula WHERE global:**
```
MSSQL_GLOBAL_WHERE_CLAUSE="CreateDate > '2023-01-01'" ./mssql_dumps.sh -S server.database.windows.net -d myDatabase -U myUser -P myPassword
```

**Incluyendo sentencias DROP TABLE:**
```
MSSQL_DROP_TABLES=true ./mssql_dumps.sh -S server.database.windows.net -d myDatabase -U myUser -P myPassword
```

**Usando variables de entorno:**
```
# Después de configurar el archivo .env
./mssql_dumps.sh
```

## Uso con Docker

El proyecto incluye un Dockerfile y configuración docker-compose para facilitar su ejecución en cualquier entorno. El Makefile proporciona comandos convenientes para trabajar con Docker:

**Construir la imagen Docker:**
```
make build
```

**Ejecutar con parámetros:**
```
make run ARGS="-S server.database.windows.net -d database -U username -P password"
```

**Ejecutar usando variables de entorno:**
```
# Crear y configurar el archivo .env primero
make setup-env
# Editar archivo .env con tus credenciales
nano .env
# Ejecutar
make run
```

**Método alternativo:**
```
docker-compose run mssql-backup -S server.database.windows.net -d database -U username -P password
```

## Estructura del archivo de backup generado

El archivo SQL generado contiene:

1. Encabezado con información del backup
2. Para cada tabla:
   - Sentencia DROP TABLE IF EXISTS (si MSSQL_DROP_TABLES está habilitado)
   - Estructura completa de la tabla (CREATE TABLE)
   - Claves primarias (ALTER TABLE ADD CONSTRAINT)
   - Activación de IDENTITY INSERT si es necesario
   - Datos como declaraciones INSERT individuales (filtrados por MSSQL_GLOBAL_WHERE_CLAUSE si está definido)
   - Desactivación de IDENTITY INSERT si fue activado
3. Declaraciones de configuración finales (SET NOCOUNT ON, etc.)

## Características avanzadas

### Verificación de salud (Health Check)

El script realiza una comprobación de salud robusta que:
- Intenta conectar a la base de datos master para obtener información de versión
- Verifica la conexión directa a la base de datos objetivo
- Comprueba el acceso a las tablas

### Cláusula WHERE global

La variable `MSSQL_GLOBAL_WHERE_CLAUSE` permite aplicar un filtro a todas las consultas de extracción de datos, lo que es útil para:
- Crear copias parciales de grandes bases de datos
- Filtrar solo datos recientes o activos
- Exportar subconjuntos específicos de datos

### Manejo de errores y fallbacks

El script incluye:
- Fallback automático para tablas sin datos binarios (utilizando formato CSV → INSERT)
- Detección de versión del servidor para usar la sintaxis más adecuada
- Manejo mejorado de credenciales y errores de conexión

## Licencia

Este proyecto está licenciado bajo la licencia MIT. Vea el archivo LICENSE para más detalles.

## Comandos del Makefile

El proyecto incluye un Makefile con comandos útiles:

* `make help`: Muestra ayuda sobre los comandos disponibles
* `make build`: Construye la imagen Docker
* `make run [ARGS="..."]`: Ejecuta el script con Docker (usando variables de entorno o argumentos)
* `make run-local [ARGS="..."]`: Ejecuta el script localmente (usando variables de entorno o argumentos)
* `make setup-env`: Crea archivo .env a partir de .env-example
* `make clean`: Elimina archivos SQL generados
* `make clean-docker`: Elimina contenedores e imágenes Docker

## Contribuciones

Las contribuciones son bienvenidas. Por favor, abra un issue para discutir los cambios que le gustaría realizar.
