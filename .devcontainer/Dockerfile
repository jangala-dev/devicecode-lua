FROM ubuntu:22.04

# Install needed packages and setup non-root user. Use a separate RUN statement to add your own dependencies.
ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=$USER_UID

# Create the user
RUN groupadd --gid $USER_GID $USERNAME \
  && useradd --uid $USER_UID --gid $USER_GID -m $USERNAME \
  && apt-get update \
  && apt-get install -y sudo curl \
  && echo $USERNAME ALL=\(root\) NOPASSWD:ALL > /etc/sudoers.d/$USERNAME \
  && chmod 0440 /etc/sudoers.d/$USERNAME

# Install Node.js 22.x from NodeSource
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - \
  && apt-get install -y nodejs

# [Optional] Clean up
RUN apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# [Optional] Set the default user. Omit if you want to keep the default as root.
USER $USERNAME
