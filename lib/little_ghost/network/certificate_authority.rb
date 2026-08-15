# frozen_string_literal: true

require "openssl"
require "open3"

module LittleGhost
  module Network
    # Creates run-scoped trust material for opt-in HTTP inspection.
    module CertificateAuthority # :nodoc:
      module_function

      def create(root:, hosts:, trust_root: File.join(root, "trust"))
        Dir.mkdir(trust_root, 0o700) unless Dir.exist?(trust_root)
        ca_key = OpenSSL::PKey::RSA.new(3072)
        ca_certificate = certificate(
          subject: "/CN=LittleGhost Ephemeral Egress CA",
          key: ca_key,
          issuer: nil,
          issuer_key: ca_key,
          serial: random_serial,
          extensions: [["basicConstraints", "critical,CA:TRUE"], ["keyUsage", "critical,keyCertSign,cRLSign"]]
        )
        leaf_key = OpenSSL::PKey::RSA.new(2048)
        leaf_certificate = certificate(
          subject: "/CN=LittleGhost Egress",
          key: leaf_key,
          issuer: ca_certificate,
          issuer_key: ca_key,
          serial: random_serial,
          extensions: [
            ["basicConstraints", "critical,CA:FALSE"],
            ["keyUsage", "critical,digitalSignature,keyEncipherment"],
            ["extendedKeyUsage", "serverAuth"],
            ["subjectAltName", hosts.map { |host| "DNS:#{host}" }.join(",")]
          ]
        )

        paths = {
          ca_key: File.join(root, "ca.key"),
          ca_certificate: File.join(trust_root, "ca.crt"),
          certificate_chain: File.join(root, "leaf.crt"),
          private_key: File.join(root, "leaf.key"),
          trust_bundle: File.join(trust_root, "ca-bundle.pem"),
          trust_store: File.join(trust_root, "ca.p12"),
          trust_root:
        }
        write(paths.fetch(:ca_key), ca_key.to_pem, 0o600)
        write(paths.fetch(:ca_certificate), ca_certificate.to_pem, 0o644)
        write(paths.fetch(:certificate_chain), leaf_certificate.to_pem, 0o644)
        write(paths.fetch(:private_key), leaf_key.to_pem, 0o600)
        system_bundle = File.file?(OpenSSL::X509::DEFAULT_CERT_FILE) ? File.binread(OpenSSL::X509::DEFAULT_CERT_FILE) : ""
        write(paths.fetch(:trust_bundle), "#{system_bundle}\n#{ca_certificate.to_pem}", 0o644)
        create_trust_store(paths.fetch(:ca_certificate), paths.fetch(:trust_store))
        paths.freeze
      end

      def certificate(subject:, key:, issuer:, issuer_key:, serial:, extensions:)
        certificate = OpenSSL::X509::Certificate.new
        certificate.version = 2
        certificate.serial = serial
        certificate.subject = OpenSSL::X509::Name.parse(subject)
        certificate.issuer = issuer ? issuer.subject : certificate.subject
        certificate.public_key = key.public_key
        certificate.not_before = Time.now - 60
        certificate.not_after = Time.now + (2 * 24 * 60 * 60)
        factory = OpenSSL::X509::ExtensionFactory.new
        factory.subject_certificate = certificate
        factory.issuer_certificate = issuer || certificate
        extensions.each { |name, value| certificate.add_extension(factory.create_extension(name, value)) }
        certificate.sign(issuer_key, OpenSSL::Digest.new("SHA256"))
        certificate
      end

      def random_serial
        OpenSSL::BN.rand(128).to_i
      end

      def write(path, content, mode)
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, mode) { |file| file.write(content) }
      end

      def create_trust_store(certificate, destination)
        _stdout, stderr, status = Open3.capture3(
          {}, "openssl", "pkcs12", "-export", "-nokeys", "-in", certificate,
          "-out", destination, "-passout", "pass:changeit", unsetenv_others: true
        )
        unless status.success?
          detail = stderr.lines.first.to_s.strip
          detail = "openssl pkcs12 failed" if detail.empty?
          raise DependencyError, "HTTP inspection could not create its Java trust store: #{detail}"
        end
        File.chmod(0o644, destination)
      rescue Errno::ENOENT
        raise DependencyError, "HTTP inspection requires the openssl executable"
      end
    end
  end
end
